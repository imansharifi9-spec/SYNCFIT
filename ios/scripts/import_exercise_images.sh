#!/usr/bin/env bash
# Imports PNG/JPG files from ios/ExerciseImagePack/ into Xcode asset catalog.
# Usage: ./ios/scripts/import_exercise_images.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK_DIR="$ROOT/ExerciseImagePack"
ASSETS_DIR="$ROOT/SyncFit/Assets.xcassets"

if [[ ! -d "$PACK_DIR" ]]; then
  echo "Missing folder: $PACK_DIR"
  exit 1
fi

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
    {
      "filename" : "$filename",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "idiom" : "universal",
      "scale" : "3x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF
}

normalize_slug() {
  local raw="$1"
  raw="${raw%.*}"
  echo "$raw" | tr '[:upper:]' '[:lower:]' | tr ' -' '__' | tr -s '_'
}

imported=0
skipped=0

shopt -s nullglob
for image_path in "$PACK_DIR"/*.{png,jpg,jpeg,PNG,JPG,JPEG}; do
  [[ -f "$image_path" ]] || continue

  base="$(basename "$image_path")"
  slug="$(normalize_slug "$base")"
  asset_name="exercise_${slug}"
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
  echo "No images found in $PACK_DIR"
  echo "Drop files named like bench_press.png, lateral_raise.png, etc."
  echo ""
  echo "Expected filenames for SyncFit's built-in exercises:"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    echo "  - $line"
  done < "$PACK_DIR/EXPECTED_FILENAMES.txt"
  exit 1
fi

echo ""
echo "Done. Imported $imported image(s)."
echo "Rebuild in Xcode (Cmd+R) to see them in the app."
echo ""
echo "Still missing? Compare your files to EXPECTED_FILENAMES.txt in ExerciseImagePack/."
