#!/usr/bin/env bash
set -euo pipefail

# CI-only fresh-database gate. Ordinary development uses the linked remote
# Supabase project; this script intentionally requires a container runtime.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
backend_dir="$(cd -- "${script_dir}/.." && pwd)"
generated_dir="${backend_dir}/src/generated"
generated_types="${generated_dir}/database.types.ts"
temp_dir="$(mktemp -d)"
local_types="${temp_dir}/database.types.ts"
normalized_committed_types="${temp_dir}/committed.normalized.ts"
normalized_local_types="${temp_dir}/local.normalized.ts"
schema_list="public,authz,ledger,financial_ops,evidence,internal,commercial,tenant_config"

cd "${backend_dir}"

cleanup() {
  supabase stop >/dev/null 2>&1 || true
  rm -f -- \
    "${local_types}" \
    "${normalized_committed_types}" \
    "${normalized_local_types}"
  rmdir -- "${temp_dir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

supabase start
supabase db reset --local --yes
supabase test db --local supabase/tests
supabase db lint --local --schema "${schema_list},command_api,read_api" --level warning --fail-on error

mkdir -p "${generated_dir}"
supabase gen types typescript --local --schema "${schema_list}" > "${local_types}"
deno fmt "${local_types}"

# Preserve generator output for reviewing drift; the gate below still fails on differences.
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  cp "${local_types}" "${RUNNER_TEMP}/elivate-database.types.ts"
fi

# Remote type generation includes PostgREST version metadata that the local
# container generator omits. Compare the schema contract after removing only
# that transport-specific block from both files.
normalize_generated_types() {
  awk '
    /^  \/\/ Allows to automatically instantiate createClient/ {
      skipping_internal_supabase = 1
      next
    }
    skipping_internal_supabase && /^  };$/ {
      skipping_internal_supabase = 0
      next
    }
    !skipping_internal_supabase { print }
  ' "$1"
}

normalize_generated_types "${generated_types}" > "${normalized_committed_types}"
normalize_generated_types "${local_types}" > "${normalized_local_types}"
diff -u "${normalized_committed_types}" "${normalized_local_types}"

printf 'Backend replay, pgTAP, and generated type drift check passed.\n'
