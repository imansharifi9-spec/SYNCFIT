#!/usr/bin/env bash
# Imports muscle-group character icons from ios/MuscleGroupImagePack/
# Usage: ./ios/scripts/import_muscle_group_images.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK_DIR="$ROOT/MuscleGroupImagePack"
ASSETS_DIR="$ROOT/SyncFit/Assets.xcassets"

mkdir -p "$PACK_DIR"

if [[ ! -d "$ASSETS_DIR" ]]; then
  echo "Missing asset catalog: $ASSETS_DIR"
  exit 1
fi

write_contents_json() {
  local imageset_dir="$1"
  local filename="$2"
  cat > "$imageset_dir/Contents.json" <<EOF
{
  "images" : [
    { "filename" : "$filename", "idiom" : "universal", "scale" : "1x" },
    { "idiom" : "universal", "scale" : "2x" },
    { "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
}

imported=0
shopt -s nullglob
for image_path in "$PACK_DIR"/*.{png,jpg,jpeg,PNG,JPG,JPEG}; do
  [[ -f "$image_path" ]] || continue
  base="$(basename "$image_path")"
  slug="${base%.*}"
  slug="$(echo "$slug" | tr '[:upper:]' '[:lower:]')"

  case "$slug" in
    arms|muscle_arms) asset_name="muscle_arms" ;;
    back|muscle_back) asset_name="muscle_back" ;;
    chest|muscle_chest) asset_name="muscle_chest" ;;
    legs|muscle_legs) asset_name="muscle_legs" ;;
    shoulders|muscle_shoulders) asset_name="muscle_shoulders" ;;
    core|muscle_core|abs|muscle_abs) asset_name="muscle_core" ;;
    cardio|muscle_cardio) asset_name="muscle_cardio" ;;
    *) echo "Skipping unknown file: $base (use arms.png, back.png, chest.png, legs.png, shoulders.png, core.png, cardio.png)"; continue ;;
  esac

  imageset_dir="$ASSETS_DIR/${asset_name}.imageset"
  dest_file="${asset_name}.png"
  mkdir -p "$imageset_dir"

  if command -v sips >/dev/null 2>&1; then
    sips -s format png "$image_path" --out "$imageset_dir/$dest_file" >/dev/null
  else
    cp "$image_path" "$imageset_dir/$dest_file"
  fi

  write_contents_json "$imageset_dir" "$dest_file"
  echo "Imported: $base -> ${asset_name}.imageset"
  imported=$((imported + 1))
done

if [[ "$imported" -eq 0 ]]; then
  echo "Drop images into $PACK_DIR"
  echo "Expected: arms.png, back.png, chest.png, legs.png, shoulders.png, core.png, cardio.png"
  exit 1
fi

echo "Done. Imported $imported muscle-group icon(s). Rebuild in Xcode (Cmd+R)."
