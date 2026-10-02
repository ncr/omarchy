#!/bin/bash

# Lists the monitors that show their own background, for MonitorBackgrounds.js:
# the output name, "image" or "folder", the target, and for a folder the image
# names in it, separated by tabs. A link whose target is gone is skipped, so that
# monitor shows the shared background again.

backgrounds_dir=${1:-$HOME/.local/state/omarchy/current/monitor-backgrounds}

is_image_path() {
  [[ ${1,,} =~ \.(jpg|jpeg|png|gif|bmp|webp)$ ]]
}

printable() {
  [[ $1 != *$'\t'* && $1 != *$'\n'* ]]
}

for link in "$backgrounds_dir"/*; do
  [[ -L $link ]] || continue
  output=${link##*/}
  target=$(readlink -f "$link") || continue
  printable "$output" && printable "$target" || continue

  if [[ -d $target ]]; then
    line="$output"$'\t'"folder"$'\t'"$target"
    for image in "$target"/*; do
      name=${image##*/}
      if [[ -f $image ]] && is_image_path "$name" && printable "$name"; then
        line+=$'\t'"$name"
      fi
    done
    printf '%s\n' "$line"
  elif [[ -f $target ]] && is_image_path "$target"; then
    printf '%s\t%s\t%s\n' "$output" "image" "$target"
  fi
done
