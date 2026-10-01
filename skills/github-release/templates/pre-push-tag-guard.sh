#!/usr/bin/env bash
# Pre-push hook: reject lightweight version tags
while read -r _local_ref _local_sha remote_ref _remote_sha; do
  if [[ "$remote_ref" == refs/tags/v* ]]; then
    tag="${remote_ref#refs/tags/}"
    obj_type=$(git cat-file -t "$tag" 2>/dev/null)
    if [[ "$obj_type" != "tag" ]]; then
      echo "ERROR: Tag $tag is lightweight (unsigned)."
      echo "Use: git tag -s $tag -m \"$tag\""
      exit 1
    fi
  fi
done
