# PrintScan 3D

An iPhone app that scans real objects with **LiDAR + photogrammetry**, previews them in 3D on the phone, and exports a **ready-to-print** model (STL, 3MF, OBJ or USDZ) that you can share by **email, Messages, Messenger, WhatsApp, AirDrop** or any other app.

## Features

| | |
|---|---|
| **Object Capture** | Apple's guided capture (`ObjectCaptureSession`) uses LiDAR to track the object and its bounding box while taking photos, then on-device photogrammetry (`PhotogrammetrySession`) builds a detailed textured mesh. Multiple passes are supported, including flipping the object to capture its underside for a fully closed model. |
| **LiDAR Quick Scan** | ARKit scene reconstruction meshes the scene live. Tap the object to drop a crop box, resize it, and capture instantly. Good for larger objects or quick drafts. |
| **Import** | Convert existing USDZ / OBJ / STL / PLY / DAE files. |
| **Print-ready pipeline** | Converts to millimeters with Z up, welds vertices, removes degenerate triangles and loose fragments, optionally cuts a flat base, fills holes (ear-clipped caps), fixes inside-out normals, and centers the part on the bed. A readiness report shows size, volume, triangle count and whether the mesh is watertight. |
| **Sizing** | Real-world size (with % scale) or fit the longest side to a target in mm. |
| **Preview** | Interactive SceneKit preview on a virtual print bed with a 10 mm grid, plus AR Quick Look to place the model in your room at real size. |
| **Sharing** | The system share sheet (Messages, Messenger, WhatsApp, Telegram, AirDrop, Save to Files, …) and an in-app email composer with the model attached. |

## Requirements

- Xcode 16 or later
- iOS / iPadOS 17 or later
- **Object Capture**: an iPhone or iPad with LiDAR and an A14 chip or newer (iPhone 12 Pro or later Pro models).
- **LiDAR Quick Scan**: any device with LiDAR.
- Other devices and the Simulator can import, preview, convert and share model files. Scanning is disabled there.

## Building

1. Open `PrintScan3D.xcodeproj` in Xcode.
2. Select the **PrintScan3D** target → *Signing & Capabilities*, choose your team, and change the bundle identifier (`com.example.PrintScan3D`) to one you own.
3. Connect a LiDAR iPhone and press **Run**.

Unit tests for the mesh pipeline (hole filling, base cut, welding, unit conversion, STL/3MF writers) are in `PrintScan3DTests`. Run them with **⌘U** on any Simulator.

## Using the app

1. Tap **+** → **Object Capture**.
2. Point at the object and tap **Continue**. Adjust the box, then tap **Start Capture**.
3. Walk slowly around the object. When the pass completes, choose **Flip Object** to scan the underside (recommended for printing), or **Process Model**.
4. Wait for on-device reconstruction (usually a few minutes; keep the app open).
5. On the model screen, check the **Print readiness** report and adjust size, flat base cut or repair options.
6. Pick an export format (STL is the default) and tap **Share…** or **Email**.

### Tips for good prints

- Use diffuse, even light, and put the object on a plain, non-reflective surface with some space around it.
- Shiny, transparent or very thin objects scan poorly with photogrammetry.
- **Small objects** (under about 15 cm) need **Object Capture**. LiDAR Quick Scan meshes the room at a resolution of a few centimeters, so small objects come out as blobs. For small items, put them on a textured, non-reflective surface (a newspaper or patterned cloth works well), fill most of the frame, and move slowly.
- If Object Capture stays on "Starting LiDAR and camera…", check that camera access is allowed in Settings, close other camera/AR apps, and tap **Restart Camera**.
- A 1–2 mm **flat base cut** helps scanned objects stick to the bed.
- 3MF stores millimeter units explicitly. STL has no units, but every slicer assumes millimeters, which is what the app writes.

### Sharing to messaging apps

The share sheet lists every installed app that accepts files. WhatsApp, Telegram, Signal, Mail, Gmail, AirDrop and Files accept STL/3MF directly. Some apps, including Facebook Messenger, only accept certain media types in their share extension. If Messenger isn't listed for an STL, export as **USDZ** (which Apple apps preview in 3D) or use **Save to Files** and attach it from Messenger.

## Project layout

```
PrintScan3D/
  App/        App entry point and scan library
  Capture/    Object Capture flow, LiDAR quick scan, Simulator stubs
  Detail/     Model screen, SceneKit print-bed preview, thumbnails
  Mesh/       TriangleMesh, repair algorithms, print pipeline,
              importers (STL, SceneKit formats), exporters (STL, 3MF, OBJ, USDZ)
  Share/      Share sheet, mail composer, AR Quick Look wrappers
PrintScan3DTests/  Mesh pipeline unit tests
Config/Info.plist  Camera usage text, Files app sharing
```

Scans live in the app's Documents folder (`Scans/<id>/`), which is also visible in the Files app under *On My iPhone → PrintScan 3D*.
