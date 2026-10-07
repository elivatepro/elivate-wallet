#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/committed-functions.sh"

configured_functions=()
while IFS= read -r function_name; do
  configured_functions+=("$function_name")
done < <(sed -n 's/^\[functions\.\([^]]*\)\]$/\1/p' supabase/config.toml)

contains_function() {
  local candidate="$1"
  local function_name

  for function_name in "${BACKEND_EDGE_FUNCTIONS[@]}"; do
    if [[ "$function_name" == "$candidate" ]]; then
      return 0
    fi
  done

  return 1
}

has_jwt_verification() {
  local candidate="$1"
  local expected="$2"

  awk -v expected="$expected" -v section="[functions.${candidate}]" '
    $0 == section {
      in_section = 1
      next
    }

    in_section && /^\[/ {
      exit found ? 0 : 1
    }

    in_section && $0 ~ ("^[[:space:]]*verify_jwt[[:space:]]*=[[:space:]]*" expected "[[:space:]]*$") {
      found = 1
    }

    END {
      exit found ? 0 : 1
    }
  ' supabase/config.toml
}

for function_name in "${BACKEND_EDGE_FUNCTIONS[@]}"; do
  test -f "supabase/functions/${function_name}/index.ts"
  contains_function "$function_name"
  expected=true
  if [[ "$function_name" == "invitation-preview" || "$function_name" == "process-payout-verifications" || "$function_name" == "submit-workspace-request" ]]; then expected=false; fi
  if ! has_jwt_verification "$function_name" "$expected"; then
    echo "Function ${function_name} must set verify_jwt = ${expected}" >&2
    exit 1
  fi
done

for function_name in "${configured_functions[@]}"; do
  contains_function "$function_name"
done

if [[ "${#configured_functions[@]}" -ne "${#BACKEND_EDGE_FUNCTIONS[@]}" ]]; then
  echo "Configured and committed Edge Function counts differ" >&2
  exit 1
fi

echo "Verified ${#BACKEND_EDGE_FUNCTIONS[@]} committed Edge Functions with exact JWT policy"
