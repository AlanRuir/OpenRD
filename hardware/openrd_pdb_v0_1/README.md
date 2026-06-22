# OpenRD PDB v0.1 EasyEDA Sources

This directory contains generated EasyEDA Standard source files for the
OpenRD power distribution board v0.1.

## Files

```text
generate_easyeda_std.py
easyeda_std/openrd_pdb_v0_1_schematic.json
easyeda_std/openrd_pdb_v0_1_pcb.json
easyeda_std/openrd_pdb_v0_1_bom.csv
easyeda_std/openrd_pdb_v0_1_easyeda_std.zip
```

The ZIP contains the schematic JSON, PCB JSON, and BOM CSV. Use the ZIP when
importing into EasyEDA Pro because the official documentation recommends
compressing schematic and PCB together when a PCB exists.

## Import

Recommended import path:

```text
EasyEDA Pro
  -> Import EasyEDA Standard
  -> Select openrd_pdb_v0_1_easyeda_std.zip
```

For EasyEDA Standard:

```text
File
  -> Open
  -> EasyEDA
  -> Select the JSON source file
```

If importing the ZIP fails, import the PCB JSON and schematic JSON separately,
then save them into a native EasyEDA project manually.

## Current Scope

This is a first-pass editable source package, not a manufacturing-ready board.

It includes:

- 95mm x 95mm board outline;
- chassis mounting holes;
- default LTC3780 module area, `78mm x 46mm x 15mm`;
- default LTC3780 mounting holes, `70mm x 38mm` spacing;
- T plug pigtail pads for battery input and motor output;
- fuse, switch, DC-DC, RK output, ADC, LED, and test pads;
- main high-current route placeholders;
- silk labels and warning text;
- BOM draft.

Before ordering:

- open the project in EasyEDA;
- run ERC/DRC;
- verify all footprints against purchased parts;
- verify Deans T polarity;
- verify DC5525 center-positive polarity;
- replace placeholder tracks with real copper pours if needed;
- print 1:1 and test-fit all modules and wires.

## Regenerate

```powershell
cd D:\Projects\OpenRD
python hardware\openrd_pdb_v0_1\generate_easyeda_std.py
```

## References

- EasyEDA Standard source export/open documentation:
  `https://docs.easyeda.com/en/Export/Export-EasyEDA-Source-File/index.html`
- EasyEDA Pro import FAQ:
  `https://prodocs.easyeda.com/en/faq/import-export/`
- EasyEDA Pro import EasyEDA Standard:
  `https://prodocs.easyeda.com/en/import-export/import-easyeda/`
