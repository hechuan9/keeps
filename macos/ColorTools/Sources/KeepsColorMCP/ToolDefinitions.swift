import Foundation
import KeepsColorCore

@MainActor func textBlock(_ object: Any) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return ["type": "text", "text": String(decoding: data, as: UTF8.self)]
}
@MainActor func imageBlock(_ url: URL) throws -> [String: Any] {
    ["type": "image", "mimeType": "image/jpeg", "data": try Data(contentsOf: url).base64EncodedString()]
}
@MainActor func objectSchema(_ fields: [String: Any], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": fields, "required": required, "additionalProperties": false]
}
@MainActor let stringField: [String: Any] = ["type": "string"]
@MainActor let candidateSchema = objectSchema(["candidateID": stringField], required: ["candidateID"])
@MainActor func maskNumber(_ minimum: Double, _ maximum: Double, _ description: String) -> [String: Any] {
    ["type": "number", "minimum": minimum, "maximum": maximum, "description": description]
}
@MainActor let ellipseSchema = objectSchema([
    "centerX": maskNumber(0, 1, "Center from left, divided by raw image width."),
    "centerY": maskNumber(0, 1, "Center from top, divided by raw image height."),
    "radiusX": maskNumber(0.002, 1, "Horizontal INNER radius divided by the shorter raw edge, not width. Full exposure applies inside this ellipse."),
    "radiusY": maskNumber(0.002, 1, "Vertical INNER radius divided by the shorter raw edge, not height."),
    "rotation": maskNumber(-180, 180, "Clockwise degrees in top-left image coordinates; 0 aligns radiusX horizontally."),
    "feather": maskNumber(0.001, 1, "OUTWARD feather width divided by the shorter raw edge. Outer radii = inner radii + feather. This extends into surrounding background; it is not an inward soft edge or percentage.")
], required: ["centerX", "centerY", "radiusX", "radiusY", "rotation", "feather"])
@MainActor let gradientSchema = objectSchema([
    "anchorX": maskNumber(0, 1, "50 percent mask anchor from left, divided by raw image width."),
    "anchorY": maskNumber(0, 1, "50 percent mask anchor from top, divided by raw image height; not the start/end of the transition."),
    "rotation": maskNumber(-180, 180, "Direction of the fully affected half-plane: 0 = TOP (sky), 90 = LEFT, -90 = RIGHT, 180 or -180 = BOTTOM. Not the direction in which opacity increases clockwise."),
    "compression": maskNumber(0.001, 1, "HALF the full linear 0-to-100 percent transition width, divided by the RAW IMAGE DIAGONAL. Full width = 2 * compression * hypot(width,height). For a horizontal transition of 20 percent image height use 0.1 * height / hypot(width,height).")
], required: ["anchorX", "anchorY", "rotation", "compression"])
@MainActor let recipeSchema: [String: Any] = objectSchema([
    "exposureEV": ["type": "number", "minimum": -5, "maximum": 5],
    "whiteBalanceRGB": ["type": "array", "items": ["type": "number", "minimum": 0.5, "maximum": 2], "minItems": 3, "maxItems": 3],
    "contrast": ["type": "number", "minimum": 0.5, "maximum": 3],
    "skew": ["type": "number", "minimum": -1, "maximum": 1],
    "saturation": ["type": "number", "minimum": 0, "maximum": 2],
    "localAdjustments": ["type": "array", "maxItems": 8, "items": objectSchema([
        "id": stringField, "exposureEV": ["type": "number", "minimum": -3, "maximum": 3],
        "mask": ["oneOf": [
            objectSchema(["ellipse": ellipseSchema], required: ["ellipse"]),
            objectSchema(["gradient": gradientSchema], required: ["gradient"]),
            objectSchema(["raster": objectSchema(["maskID": stringField, "invert": ["type": "boolean"]], required: ["maskID", "invert"])], required: ["raster"])
        ]]
    ], required: ["id", "exposureEV", "mask"])]
])
@MainActor let tools: [[String: Any]] = [
    ["name": "generate_mask", "description": "Generate and show an actual semantic soft mask from the original photo. person uses person segmentation; background is the complement of all detected foreground subjects; sky uses a dedicated sky segmentation model. White pixels receive the adjustment. Inspect the returned mask before using its maskID in a raster local adjustment. Failure never falls back to geometry.", "inputSchema": objectSchema(["kind": ["type": "string", "enum": ["person", "background", "sky"]]], required: ["kind"])],
    ["name": "preview_region", "description": "Inspect a subject/face region from the original or initial candidate before adjusting. Adjusted candidates cannot be inspected; the human chooses the result. x/y are normalized from TOP LEFT; width/height normalized by image size. Returns an enlarged crop and display-luma statistics, not a quality score.", "inputSchema": objectSchema(["candidateID": stringField, "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]], required: ["candidateID", "x", "y", "width", "height"])],
    ["name": "inspect_photo", "description": "Read the initial engine-rendered photo and persisted candidate IDs. No camera JPEG target.", "inputSchema": objectSchema([:])],
    ["name": "get_recipe", "description": "Read a complete immutable recipe by candidateID. WB is source-relative RGB multipliers; exposure in EV; mask centers measured from TOP LEFT and normalized to image width/height, radii/feather to shorter image edge, rotations in degrees. Ellipse feather extends OUTWARD. Gradient rotation 0 covers TOP, 90 LEFT, -90 RIGHT, 180 BOTTOM; compression is HALF the linear transition width normalized to the image diagonal. Ellipse and gradient are geometric masks; use generate_mask for true person/background/sky segmentation. Raster masks are returned as opaque maskID references; their pixels are retained in the persisted recipe.", "inputSchema": candidateSchema],
    ["name": "set_adjustments", "description": "Create immutable candidate from parentID with absolute overrides. operationID makes identical retries idempotent. localAdjustments replaces entire local list. Create at most one new candidate per run. Inspect the initial photo first, apply one coherent adjustment, then render_preview for human choice. Parent remains unchanged.", "inputSchema": objectSchema(["operationID": stringField, "parentID": stringField, "adjustments": recipeSchema], required: ["operationID", "parentID", "adjustments"])],
    ["name": "render_preview", "description": "Render an sRGB preview for the human to choose. Returns candidate ID, local preview path and readiness; no image pixels, quality judgment or full-size export.", "inputSchema": candidateSchema]
]
