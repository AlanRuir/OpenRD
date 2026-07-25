#!/usr/bin/env python3
"""Minimal WHIP publisher for the OpenRD RK3588 camera pipeline.

This keeps the low-latency WebRTC path available on Debian 11 images that have
GStreamer webrtcbin but do not package the newer whipsink element.
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstSdp", "1.0")
gi.require_version("GstWebRTC", "1.0")

from gi.repository import GLib, Gst, GstSdp, GstWebRTC  # noqa: E402


def gst_quote(value: str) -> str:
    return json.dumps(str(value))


def build_source(args: argparse.Namespace) -> str:
    src = [
        f"v4l2src device={gst_quote(args.device)}",
    ]
    if args.buffers > 0:
        src.append(f"num-buffers={args.buffers}")

    if args.input_format == "nv12":
        src.extend(
            [
                "!",
                (
                    f"video/x-raw,format=NV12,width={args.width},"
                    f"height={args.height},framerate={args.fps}/1"
                ),
            ]
        )
    elif args.input_format == "mjpg":
        src.extend(
            [
                "!",
                (
                    f"image/jpeg,width={args.width},height={args.height},"
                    f"framerate={args.fps}/1"
                ),
            ]
        )
        if args.mjpeg_decoder == "mpp":
            src.extend(["!", "jpegparse", "!", "mppjpegdec format=NV12"])
        else:
            src.extend(["!", "jpegdec", "!", "videoconvert"])
        src.extend(["!", "video/x-raw,format=NV12"])
    else:
        raise ValueError(f"unsupported input format: {args.input_format}")

    return " ".join(src)


def build_pipeline(args: argparse.Namespace) -> str:
    return " ".join(
        [
            build_source(args),
            "!",
            (
                f"mpph264enc bps={args.bitrate} gop={args.gop} "
                f"profile={args.h264_profile} header-mode={args.h264_header_mode}"
            ),
            "!",
            "queue leaky=downstream max-size-buffers=2",
            "!",
            "h264parse config-interval=1",
            "!",
            "video/x-h264,stream-format=byte-stream,alignment=au",
            "!",
            (
                f"rtph264pay pt={args.rtp_pt} config-interval=1 "
                f"mtu={args.rtp_mtu}"
            ),
            "!",
            (
                "application/x-rtp,media=video,encoding-name=H264,"
                f"payload={args.rtp_pt},clock-rate=90000"
            ),
            "!",
            "queue name=rtpqueue leaky=downstream max-size-buffers=2",
        ]
    )


def rtp_caps(args: argparse.Namespace) -> Gst.Caps:
    return Gst.Caps.from_string(
        (
            "application/x-rtp,media=video,encoding-name=H264,"
            f"payload={args.rtp_pt},clock-rate=90000"
        )
    )


def attach_webrtcbin(pipeline: Gst.Pipeline, args: argparse.Namespace) -> Gst.Element:
    webrtc = Gst.ElementFactory.make("webrtcbin", "webrtc")
    if webrtc is None:
        raise RuntimeError("failed to create webrtcbin")
    webrtc.set_property("bundle-policy", GstWebRTC.WebRTCBundlePolicy.MAX_BUNDLE)
    pipeline.add(webrtc)

    queue = pipeline.get_by_name("rtpqueue")
    if queue is None:
        raise RuntimeError("RTP queue was not found in pipeline")

    srcpad = queue.get_static_pad("src")
    if srcpad is None:
        raise RuntimeError("RTP queue src pad was not found")

    template = webrtc.get_pad_template("sink_%u")
    if template is None:
        raise RuntimeError("webrtcbin sink_%u pad template was not found")

    sinkpad = webrtc.request_pad(template, None, rtp_caps(args))
    if sinkpad is None:
        raise RuntimeError("failed to request webrtcbin sink pad")

    link_result = srcpad.link(sinkpad)
    if link_result != Gst.PadLinkReturn.OK:
        raise RuntimeError(f"failed to link RTP queue to webrtcbin: {link_result.value_nick}")

    return webrtc


def extract_sdp_answer(body: str) -> str:
    stripped = body.strip()
    if not stripped:
        raise RuntimeError("WHIP endpoint returned an empty SDP answer")
    if stripped.startswith("{"):
        parsed = json.loads(stripped)
        for key in ("sdp", "answer", "data"):
            value = parsed.get(key)
            if isinstance(value, str) and value.strip():
                return value
        raise RuntimeError(f"WHIP JSON response has no SDP answer keys: {sorted(parsed)}")
    return stripped


def zlm_webrtc_url(url: str, mode: str) -> str | None:
    parsed = urllib.parse.urlsplit(url)
    query = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
    if not query.get("app") or not query.get("stream"):
        return None
    query["type"] = mode
    return urllib.parse.urlunsplit(
        (
            parsed.scheme,
            parsed.netloc,
            "/index/api/webrtc",
            urllib.parse.urlencode(query),
            "",
        )
    )


def is_zlm_webrtc_url(url: str) -> bool:
    parsed = urllib.parse.urlsplit(url)
    return parsed.path.rstrip("/") == "/index/api/webrtc"


@dataclass
class WhipClient:
    args: argparse.Namespace
    pipeline: Gst.Pipeline
    webrtc: Gst.Element
    loop: GLib.MainLoop
    posted: bool = False
    local_description_ready: bool = False
    failed: bool = False

    def start(self) -> int:
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self.on_bus_message)

        self.webrtc.connect("on-negotiation-needed", self.on_negotiation_needed)
        self.webrtc.connect("on-ice-candidate", self.on_ice_candidate)
        self.webrtc.connect("notify::ice-gathering-state", self.on_ice_gathering_state)
        self.webrtc.connect("notify::connection-state", self.on_connection_state)

        GLib.timeout_add_seconds(self.args.offer_timeout_sec, self.on_offer_timeout)

        result = self.pipeline.set_state(Gst.State.PLAYING)
        if result == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("failed to set WHIP pipeline to PLAYING")

        self.loop.run()
        self.pipeline.set_state(Gst.State.NULL)
        return 1 if self.failed else 0

    def stop(self, *_: object) -> None:
        self.loop.quit()

    def on_bus_message(self, _bus: Gst.Bus, message: Gst.Message) -> None:
        if message.type == Gst.MessageType.ERROR:
            err, debug = message.parse_error()
            print(f"gstreamer error: {err}; debug={debug}", file=sys.stderr)
            self.failed = True
            self.loop.quit()
        elif message.type == Gst.MessageType.EOS:
            print("gstreamer eos", file=sys.stderr)
            self.loop.quit()

    def on_negotiation_needed(self, element: Gst.Element) -> None:
        promise = Gst.Promise.new_with_change_func(self.on_offer_created, element, None)
        element.emit("create-offer", None, promise)

    def on_offer_created(self, promise: Gst.Promise, element: Gst.Element, _data: object) -> None:
        reply = promise.get_reply()
        offer = reply.get_value("offer")
        if offer is None:
            print("create-offer returned no offer", file=sys.stderr)
            self.loop.quit()
            return
        element.emit("set-local-description", offer, Gst.Promise.new())
        self.local_description_ready = True

    def on_ice_candidate(self, _element: Gst.Element, _mlineindex: int, _candidate: str) -> None:
        # WHIP supports trickle through PATCH, but this client waits for ICE gathering
        # and posts one complete SDP offer.
        return

    def on_ice_gathering_state(self, element: Gst.Element, _param: object) -> None:
        state = element.get_property("ice-gathering-state")
        print(f"ice_gathering_state={state.value_nick}", flush=True)
        if state == GstWebRTC.WebRTCICEGatheringState.COMPLETE:
            self.safe_post_offer()

    def on_connection_state(self, element: Gst.Element, _param: object) -> None:
        state = element.get_property("connection-state")
        print(f"connection_state={state.value_nick}", flush=True)
        if state in (
            GstWebRTC.WebRTCPeerConnectionState.FAILED,
            GstWebRTC.WebRTCPeerConnectionState.CLOSED,
        ):
            self.loop.quit()

    def on_offer_timeout(self) -> bool:
        if not self.posted and self.local_description_ready:
            print("posting WHIP offer before ICE gathering completed", flush=True)
            self.safe_post_offer()
        elif not self.posted:
            print("WHIP offer was not created before timeout", file=sys.stderr)
            self.failed = True
            self.loop.quit()
        return False

    def safe_post_offer(self) -> None:
        try:
            self.post_offer()
        except Exception as exc:
            print(f"WHIP offer failed: {exc}", file=sys.stderr)
            self.failed = True
            self.loop.quit()

    def post_offer(self) -> None:
        if self.posted:
            return

        local_description = self.webrtc.get_property("local-description")
        if local_description is None:
            if self.local_description_ready:
                return
            raise RuntimeError("local SDP description is not ready")

        self.posted = True
        offer_sdp = local_description.sdp.as_text()
        candidate_urls = [self.args.whip_url]
        fallback_url = zlm_webrtc_url(self.args.whip_url, "push")
        if fallback_url and fallback_url not in candidate_urls:
            candidate_urls.append(fallback_url)

        last_error: Exception | None = None
        body = ""
        for url in candidate_urls:
            try:
                body = self.post_sdp(url, offer_sdp)
                if url != self.args.whip_url:
                    print(f"WHIP fallback accepted by {url}", flush=True)
                break
            except urllib.error.HTTPError as exc:
                body = exc.read().decode("utf-8", errors="replace")
                last_error = RuntimeError(f"HTTP {exc.code}: {body[:500]}")
                if exc.code == 404 and url != candidate_urls[-1]:
                    print(f"WHIP endpoint returned 404, trying fallback: {candidate_urls[-1]}", flush=True)
                    continue
                raise RuntimeError(f"WHIP POST failed at {url}: {last_error}") from exc
            except urllib.error.URLError as exc:
                last_error = exc
                if url != candidate_urls[-1]:
                    continue
                raise RuntimeError(f"WHIP POST failed at {url}: {exc}") from exc
        else:
            raise RuntimeError(f"WHIP POST failed: {last_error}")

        answer_sdp = extract_sdp_answer(body)
        result, sdp_message = GstSdp.SDPMessage.new_from_text(answer_sdp)
        if result != GstSdp.SDPResult.OK:
            raise RuntimeError(f"failed to parse WHIP SDP answer: {result}")

        answer = GstWebRTC.WebRTCSessionDescription.new(
            GstWebRTC.WebRTCSDPType.ANSWER,
            sdp_message,
        )
        self.webrtc.emit("set-remote-description", answer, Gst.Promise.new())
        print("WHIP SDP answer applied", flush=True)

    def post_sdp(self, url: str, offer_sdp: str) -> str:
        content_type = "text/plain;charset=utf-8" if is_zlm_webrtc_url(url) else "application/sdp"
        request = urllib.request.Request(
            url,
            data=offer_sdp.encode("utf-8"),
            method="POST",
            headers={
                "Accept": "application/sdp, application/json",
                "Content-Type": content_type,
                "User-Agent": "openrd-video-whip-client/0.1",
            },
        )
        if self.args.auth_token:
            request.add_header("Authorization", f"Bearer {self.args.auth_token}")

        with urllib.request.urlopen(request, timeout=self.args.http_timeout_sec) as response:
            status = response.getcode()
            body = response.read().decode("utf-8", errors="replace")

        if status not in (200, 201):
            raise RuntimeError(f"HTTP {status}: {body[:500]}")
        return body


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="OpenRD GStreamer webrtcbin WHIP publisher")
    parser.add_argument("--whip-url", required=True)
    parser.add_argument("--auth-token", default="")
    parser.add_argument("--device", required=True)
    parser.add_argument("--input-format", choices=("mjpg", "nv12"), default="mjpg")
    parser.add_argument("--mjpeg-decoder", choices=("mpp", "software"), default="mpp")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--bitrate", type=int, default=2_000_000)
    parser.add_argument("--gop", type=int, default=30)
    parser.add_argument("--h264-profile", choices=("baseline", "main", "high"), default="baseline")
    parser.add_argument("--h264-header-mode", choices=("first-frame", "each-idr"), default="each-idr")
    parser.add_argument("--rtp-pt", type=int, default=96)
    parser.add_argument("--rtp-mtu", type=int, default=1200)
    parser.add_argument("--buffers", type=int, default=0)
    parser.add_argument("--offer-timeout-sec", type=int, default=8)
    parser.add_argument("--http-timeout-sec", type=int, default=10)
    parser.add_argument("--print-pipeline", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    Gst.init(None)

    pipeline_description = build_pipeline(args)
    if args.print_pipeline:
        print(pipeline_description)

    pipeline = Gst.parse_launch(pipeline_description)
    if not isinstance(pipeline, Gst.Pipeline):
        raise RuntimeError("parsed GStreamer description is not a pipeline")
    webrtc = attach_webrtcbin(pipeline, args)

    loop = GLib.MainLoop()
    client = WhipClient(args=args, pipeline=pipeline, webrtc=webrtc, loop=loop)
    signal.signal(signal.SIGINT, client.stop)
    signal.signal(signal.SIGTERM, client.stop)
    return client.start()


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        print(f"openrd-video-whip-client error: {exc}", file=sys.stderr)
        raise SystemExit(1)
