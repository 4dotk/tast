PSX BOOKSHELVES & FOOD SHELVES - NORMAL + NIGHTMARE
===================================================

12 fully stocked PS1-style bookcases, pantries and store shelves - tidy, and abandoned. Free.

  Normal/     neat, stocked and dusted
  Horror/     the same shelves ransacked, books on the floor, stock gone off

Both versions share the same layout and object names, so you can swap them
in a single frame and nothing moves - only the mood changes.


WHAT'S INSIDE
-------------
Each folder has the full scene as:
  .glb    (Godot, Unity, Unreal, three.js - textures embedded)
  .fbx    (Unity, Unreal - textures embedded)
  .blend  (Blender 4.2+, source file)

Normal/Items/ and Horror/Items/ hold every prop as its own .glb, centred
at the origin, ready to drop into a scene.

Godot_Demo/ is a ready-to-run Godot 4 project: open project.godot, press F5,
walk with WASD + mouse, press F to swap Normal and Nightmare.

Textures/ holds every texture as a PNG (189 files, 15-bit PS1 colour).
Import with point/nearest filtering for the PS1 look.

Scale: 1 unit = 1 metre. Scene is about 10.4 x 8.1 x 3 m.
About 38060 triangles (Normal) / 37740 (Horror).


OBJECTS (identical names in both versions)
------------------------------------------
  Display_Floor, Display_Ceiling, Display_Wall_Back, Display_Wall_Front,
  Display_Wall_Left, Display_Wall_Right, Display_Skirting,
  Display_Pad_001-011, Display_Label_001-011, Bookcase_Tall,
  Bookcase_Short, Bookcase_Empty, LibraryBay, Display_WallPanel_005-011,
  WallShelf, BookPile, PantryShelf, StoreShelf, WireRack, BreadRack,
  SpiceRack, CeilingLight_01-06, Light_01-06

Horror-only extras (collection "Horror_Extras"):
  

Lights: spot/point lights tuned for Godot 4 (energy ~1-2). In Unity or
Unreal the imported intensity may need adjusting to taste.
Flicker: in the horror version Light_01, Light_03, Light_05 are the lit one(s) - toggle
them on/off in your engine for a flicker (the Godot demo does this).


HOW TO DO THE SWAP (any engine)
-------------------------------
Load both at the same position. Show Normal, hide Horror.
When the scare fires, hide Normal and show Horror in the same frame.


LICENCE
-------
See LICENSE.txt. Use it in commercial games freely; just don't resell
the assets themselves.
