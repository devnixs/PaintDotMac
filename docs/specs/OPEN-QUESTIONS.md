# Open questions across the PaintDotMac spec backlog (221)

Each recommended answer is already written into its spec. This file is a working list: once the
answers are recorded in PRD.md §12 and the specs, delete it.

Each line gives the spec, the question, and the recommendation after the arrow. ✓ means the
recommendation is simply "yes, keep it as stated". Reply "accept all", or list the numbers you want
changed.

1. 0014 No resize handles after drawing a rectangle/ellipse selection; resizing is left to Move Selection → keep
2. 0014 Zoom to Selection is disabled with no selection → disabled
3. 0014 A drag counts as moved only when the pointer reaches another pixel → keep
4. 0014 Selection mode and clipping are shared by all selection tools → keep
5. 0028 Non-integer DPI is rounded when saving .ora → round
6. 0028 Layer groups in imported .ora files are flattened → flatten
7. 0028 An .ora with a missing or damaged layer PNG is refused → refuse
8. 0018 Erase/Fill Selection act on the whole layer when nothing is selected ✓
9. 0018 Fill Selection overwrites rather than blends (inconsistent with #22) → overwrite
10. 0018 Shift+⌫ (fill with the secondary color) is not mapped → unmapped
11. 0019 One history step per mouse-up and per arrow key; no "Finish Selection" step ✓
12. 0019 With no selection, Move Selection does Select All first ✓
13. 0019 An outline moved fully off the canvas becomes no selection but can be dragged back ✓
14. 0019 Include the rotation band outside the frame and ⌥ to scale about the center → include
15. 0020 Escape cancels the whole move (Paint.NET's Escape commits) → cancel
16. 0020 The layer shows floating pixels; saving doesn't finish them ✓
17. 0020 Undo, redo, jump and save never finish floating pixels; other commands add "Finish Pixels" first ✓
18. 0020 Scale handles snap to whole pixels while unrotated ✓
19. 0021 Cut leaves transparent black and deselects → yes
20. 0021 Cut is disabled with no selection ✓
21. 0021 Paste into New Image puts the pixels on a white Background → yes
22. 0021 Pasted pixels blend normally rather than overwrite → normal blend
23. 0021/0022 After a canvas-size change, keep the zoom and re-center ✓
24. 0022 Crop makes unselected pixels transparent black and scales edge alpha by selection coverage ✓
25. 0022 The selection is kept after a crop, moved to the new origin ✓
26. 0023 The Gradient's Antialiasing option only affects the selection edge ✓
27. 0023 Gradient colors are captured when the gradient is created → yes
28. 0023 Transparency Mode follows Paint.NET's documented rule → follow Paint.NET
29. 0029 The flatten-on-save prompt is asked once per document session per file and format ✓
30. 0029 JPEG export puts transparency onto white ✓
31. 0029 GIF export uses an alpha threshold of 128, with no dithering ✓
32. 0029 BMP files carry no sRGB profile (exception to FMT-B); 32-bit when any pixel is transparent ✓
33. 0029 HEIC is saved at fixed quality 0.90 with no dialog ✓
34. 0029 The JPEG Options dialog appears on every JPEG save; quality 0–100, default 95 ✓
35. 0029 Wording of the JPEG Options dialog and the "Flatten image?" prompt ✓
36. 0026/0027 Blend math can differ from Paint.NET by up to ±5/±7 on semi-transparent pixels (exact when both pixels are opaque) → accept
37. 0024 A duplicated layer is named "<name> copy" ✓
38. 0024 Merge Down merges a hidden upper layer anyway ✓
39. 0024 Flatten keeps the bottom layer's name ✓
40. 0024 Deleting a layer makes the layer below active ✓
41. 0024 Until 0029 lands, saving a layered image as PNG is refused ✓
42. 0024 Switching layers isn't a history step ✓
43. 0025 History steps for the visibility checkbox are named "Hide Layer"/"Show Layer" ✓
44. 0025 Dragging a layer several positions is one history step ✓
45. 0030 An imported layer is named after the file, without extension ✓
46. 0030 Import or drop places pixels at (0,0); a single file floats, several files are placed directly ✓
47. 0030 Importing a layered .ora adds its composite as one layer ✓
48. 0030 Copy Merged is ⇧⌘C ✓
49. 0030 Import grows the canvas automatically with no prompt ✓
50. 0031 One shared ⌘F "Repeat" for adjustments and effects ✓
51. 0031 Effect parameters are remembered for the session only ✓
52. 0031 Effects run on hidden layers ✓
53. 0031 Adjustments also change the color stored under fully transparent pixels ✓
54. 0031 The progress sheet appears after 0.5 s ✓
55. 0035 Resize Image clears the selection → clear
56. 0035 Supersampling falls back to Bicubic when enlarging ✓
57. 0035 Bilinear and Bicubic use simple kernels that alias on big reductions → keep
58. 0035 Changing the resolution keeps the print size, so the pixel count changes ✓
59. 0035 The Resize dialog starts from defaults every time; no extra Paint.NET 5 resamplers ✓
60. 0035 The print-size unit starts as cm when the status bar shows cm ✓
61. 0032 Black and White ⇧⌘G, Sepia ⇧⌘E, Posterize ⇧⌘P → keep
62. 0032 Sepia has no dialog ✓
63. 0032 Hue/Saturation uses exact integer math (differs from Paint.NET 3.36 by a few levels on under 0.5% of colors) → accept
64. 0032 Saturation range 0–200, default 100 ✓
65. 0036 Canvas Size fills new area with the secondary color on the bottom layer; no Fill choice ✓
66. 0036 With a centered anchor, an odd extra pixel goes on the right or bottom ✓
67. 0036 The selection is kept on the same pixels after Canvas Size ✓
68. 0036 Canvas Size dialog defaults; history step named "Canvas Size" ✓
69. 0036 Editing the resolution field changes the document's DPI ✓
70. 0033 The Levels histogram ignores alpha (Paint.NET 3.36) → mirror 3.36
71. 0033 Paint.NET 3.36's Levels dialog quirks are not reproduced ✓
72. 0033 Auto-Level does nothing if any one channel is flat → mirror 3.36
73. 0033 Auto-Level is ⇧⌘L ✓
74. 0037 Flip/Rotate Image transforms the selection along with the image → transform
75. 0034 Curves points are removed only by right-click or Control-click → yes
76. 0034 Curves keeps both the Luminosity and RGB curves ✓
77. 0034 Clicking near an existing point moves it instead of adding one ✓
78. 0038 Line/Curve is one Bézier with 4 handles plus drag-to-bend; no extra curve types ✓
79. 0038 ⌘Z while a line is still editable commits it, then undoes it ✓
80. 0038 Dash styles, cap styles and arrowhead size ✓
81. 0040 Escape commits text (Paint.NET behavior) → commit
82. 0040 Text size in points at the document's DPI (12 pt at 96 DPI = 16 px) ✓
83. 0040 Text tool has a Blend mode option ✓
84. 0040 No text clipboard; menu commands commit the text first ✓
85. 0040 Text being typed takes on primary-color changes live ✓
86. 0039 Starter shapes: Paint.NET 5's Basic group (8 shapes) ✓
87. 0039 Outline drawn inside the box, pixel-exact highlight rectangles ✓
88. 0039 Shape editing gestures reuse Move Selection's handles ✓
89. 0039 One "Shapes" history step per shape ✓
90. 0039 Shapes tool defaults ✓
91. 0039 A / Shift+A cycle through shape types ✓
92. 0041 Gaussian Blur: Paint.NET 3.36's kernel shape with exact math and edge clamping (not a bit-exact port) ✓
93. 0041 Motion Blur: same approach as Gaussian Blur ✓
94. 0041 No Paint.NET 5 extra blur options → omit
95. 0044 Emboss and Edge Detect output fully opaque pixels → keep
96. 0044 Emboss and Edge Detect clamp at the image edges → clamp
97. 0044 Pixelate uses Paint.NET 3.36's corner-blend algorithm ✓
98. 0044 Edge Detect is the 3.36 angle-based version ✓
99. 0044 Angle range −180…180 ✓
100. 0042 Sharpen has only Amount (1–20, default 2) ✓
101. 0042 Sharpen reproduces 3.36's off-by-one median exactly → keep
102. 0042 Vignette follows Paint.NET's algorithm and ranges ✓
103. 0042 Vignette's center is relative to the selection bounds ✓
104. 0043 ⌘F Repeat on Add Noise/Clouds uses a fresh random seed ✓
105. 0043 Parameter labels follow the Paint.NET 5 docs ✓
106. 0043 Clouds has 256 distinct patterns (byte seed, as in 3.36) ✓
107. 0043 Ranges and defaults from the 3.36 source ✓
108. 0043 Add Noise uses its own deterministic per-pixel random numbers, so output never matches Paint.NET pixel for pixel ✓
109. 0046 "Checkerboard style" = brightness and size popups ✓
110. 0046 "Restore panel positions" = a Reset Panel Positions button ✓
111. 0046 The Settings unit and the status-bar unit are the same setting ✓
112. 0046 Lowering the undo limit applies immediately; presets from 256 MB to 8 GB ✓
113. 0046 Settings is one grouped pane; changes apply immediately ✓
114. 0045 Go to Layer Above/Below are ⌥⇞/⌥⇟ ✓
115. 0045 Brightness/Contrast is ⇧⌘T ✓
116. 0045 Line/Curve's , . / keys are not mapped ✓
117. 0045 The other unmapped Paint.NET shortcuts stay unmapped ✓
118. 0045 Layer Rotate/Zoom has no shortcut (Paint.NET's collides with Redo) ✓
119. 0047 Autosave runs 30 s after a change ✓
120. 0047 Recovery restores the layers as displayed, but not the selection or undo history ✓
121. 0047 The recovered autosave wins over a changed original file ✓
122. 0047 No recovery UI of our own; macOS window restoration only ✓
123. 0048 New Benchmarks target, scheme and build configuration ✓
124. 0048 Benchmarks run only with the gate's `--benchmarks` option ✓
125. 0048 If an NF target can't be met on your Mac, you decide whether to relax it or add a follow-up spec ✓
126. 0048 "120 fps" is tested as at most 8.33 ms of work per frame; real 120 Hz is a manual check ✓
127. 0048 While a background Magic Wand fill is running, a second click is ignored and other actions cancel it ✓
128. 0049 VoiceOver reads the canvas as the image size, with zoom/layer/tool in its help text ✓
129. 0049 What Increase Contrast changes ✓
130. 0049 The color wheel is adjustable with VoiceOver but isn't in the Tab order ✓
131. 0049 Curves points can't be edited from the keyboard ✓
132. 0049 Keyboard model for the panels and lists ✓
133. 0050 App icon: white paintbrush and canvas frame on orange #D9480F → accept or name another design
134. 0050 No custom .ora document icon ✓
135. 0050 Version set to 1.0.0, build number 1 ✓
136. 0050 About panel shows "© 2026 Thera Engineering" with no credits line ✓
137. 0050 The 30 MB size limit means 30,000,000 bytes of the universal Release app ✓
138. 0052 Docking is done with commands, not dragging ✓
139. 0052 Tools docks on the left; History, Layers and Colors stack on the right ✓
140. 0052 By default all panels float ✓
141. 0052 Reset Panel Positions also resets the dock layout ✓
142. 0052 Docked History/Layers show their own window's document; a window widens to fit its docks ✓
143. 0051 All NF requirements count as P0 for the coverage test ✓
144. 0051 Which statements without an ID count as P0 requirements ✓
145. 0051 Use case 2's test starts from a PNG photo ✓
146. 0051 New test hook `-UITestWindowContentSize` ✓
147. 0053 Pixel Grid is ⌘' ✓
148. 0053 Rulers is ⌥⌘R ✓
149. 0053 Grid and ruler toggles are app-wide, saved, and off by default ✓
150. 0053 The pixel grid appears from 200% zoom, with the look specified ✓
151. 0053 Ruler details; no guides ✓
152. 0054 The default 96-color palette is transcribed from a Paint.NET palette file ✓
153. 0054 The screen eyedropper sets the active color slot ✓
154. 0054 How lenient palette-file parsing is ✓
155. 0054 Add Color mode ends after one replacement ✓
156. 0054 Palettes save and load by name, as in Paint.NET, with no file dialogs ✓
157. 0055 Force Touch trackpad pressure is ignored ✓
158. 0055 Pressure Sensitivity option (Off/Size/Opacity/Both), default Size ✓
159. 0055 Width at zero pressure is 10% of the brush width, linear response ✓
160. 0055 The pressure option is always shown ✓
161. 0055 The brush outline shows the full width, not the pressure width ✓
162. 0056 Clone Stamp keeps a fixed (aligned) offset only ✓
163. 0056 Clone Stamp gets a Layer/Image sampling option ✓
164. 0056 A source outside the canvas counts as transparent ✓
165. 0056 Dragging with no source set does nothing; a hint is shown ✓
166. 0056 Clone Stamp uses the Paintbrush defaults ✓
167. 0057 Recolor has "Once" and "Secondary Color" sampling, default Secondary Color ✓
168. 0057 Recolor shifts alpha too (Paint.NET 4/5 behavior) ✓
169. 0057 Recolor's color match is all-or-nothing ✓
170. 0057 Recolor has pressure sensitivity and uses the Magic Wand's tolerance ✓
171. 0059 The extra blend modes use the W3C formulas (Paint.NET doesn't define them) ✓
172. 0059 They are added after Xor in the menus ✓
173. 0058 Names of the extended shapes ✓
174. 0058 Shape geometry defined by the spec (Paint.NET shows only icons) ✓
175. 0058 The Rounded Rectangle Callout has a fixed 10% corner radius ✓
176. 0058 Grouped shape picker; A cycles through all 29 shapes ✓
177. 0061 Auto-Crop is a PaintDotMac addition on ⌥⌘X (not found in Paint.NET's docs) ✓
178. 0061 The border color is the top-left pixel ✓
179. 0061 Exact color match, no tolerance ✓
180. 0061 The selection is kept after Auto-Crop ✓
181. 0061 Auto-Crop with nothing to trim does nothing, with no message ✓
182. 0061 Auto-Crop sits right after Crop to Selection in the Image menu ✓
183. 0060 Rotate/Zoom controls (angle, pan, zoom, sampling) ✓
184. 0060 Layer flips ignore the selection; Rotate/Zoom works like an effect ✓
185. 0060 Add Layers ▸ Rotate 180°; menu and history names ✓
186. 0060 The Rotate/Zoom dialog always opens at defaults and isn't a Repeat target ✓
187. 0062 History stored on disk is limited to 4× the undo limit, keeping at least 2 GiB free ✓
188. 0062 The Settings note becomes "older history steps are moved to disk" ✓
189. 0062 A warning appears if history on disk can't be read ✓
190. 0062 A "Loading History" progress sheet for long jumps ✓
191. 0062 History files go in ~/Library/Caches/PaintDotMac/History/ ✓
192. 0063 WebP export only where ImageIO can write it; no libwebp dependency → no libwebp
193. 0063 No WebP "Lossless" checkbox ✓
194. 0063 A WebP Options sheet, default quality 95 ✓
195. 0063 WebP may lack an embedded sRGB profile, as with BMP ✓
196. 0064 Radial and Zoom Blur keep 3.36's sampling layout but with smooth sampling ✓
197. 0064 Surface Blur and Unfocus handle transparency correctly, unlike 3.36 ✓
198. 0064 Blur center range is −1…1 of the selection bounds ✓
199. 0064 No Paint.NET 5 extras for Zoom/Radial Blur ✓
200. 0064 Unfocus is kept (Paint.NET 5 replaced it with Bokeh) ✓
201. 0064 Surface Blur is slow at large radii; only measured, not optimized → accept
202. 0065 Glow and Soften Portrait are built from our own blur and adjustments ✓
203. 0065 Red Eye Removal uses 3.36's parameters plus a hint to select the eyes first ✓
204. 0065 Red Eye Removal uses exact integer math ✓
205. 0066 Median, Reduce Noise and Outline reproduce 3.36's off-by-one exactly ✓
206. 0066 Outline keeps a 3.36 transparency bug → keep (or fix)
207. 0066 Median stays under Noise, as the PRD says ✓
208. 0066 Relief uses the same approach as Edge Detect ✓
209. 0066 No Paint.NET 5 Quality options ✓
210. 0067 Distort effects use 3.36's geometry with smooth sampling ✓
211. 0067 Center and radius are relative to the selection bounds ✓
212. 0067 Paint.NET 3.36 parameter sets only ✓
213. 0067 Labels "Scale", "Offset" and "Amount / Direction" ✓
214. 0068 Ink Sketch keeps the source transparency → keep
215. 0068 Oil Painting is a bit-exact port of 3.36 ✓
216. 0068 Ink and Pencil Sketch are built from our own Glow and Blur ✓
217. 0068 Ranges and defaults from the 3.36 source ✓
218. 0069 Fractals computed in single precision (pixels near the set boundary differ from Paint.NET) ✓
219. 0069 Fractals fit the selection and have a Blend mode ✓
220. 0069 Drop Shadow parameters and math ✓
221. 0069 Outline Object (a plugin, not a Paint.NET effect) defined by the spec → keep, or remove it from PRD §5.9
