#!/usr/bin/env bash
# Corre todo el test suite de install-emby-custom.sh y devuelve 0 solo si
# todo pasó. Uso: ./tests/run_tests.sh
#
# No depende de nada fuera de bash/coreutils -- ver tests/README.md.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITES=(
    "$HERE/unit/test_escaping.sh"
    "$HERE/unit/test_injection_helpers.sh"
    "$HERE/unit/test_css_embedding.sh"
    "$HERE/unit/test_theme_injection.sh"
    "$HERE/unit/test_api_proxy_rewrite.sh"
    "$HERE/unit/test_config_file.sh"
    "$HERE/integration/test_rollback_failure_states.sh"
    "$HERE/integration/test_reapply_failure_states.sh"
)

OVERALL_FAILED=0

for suite_script in "${SUITES[@]}"; do
    echo
    echo "######################################################################"
    echo "# $(basename "$suite_script")"
    echo "######################################################################"
    if ! bash "$suite_script"; then
        OVERALL_FAILED=1
    fi
done

echo
if [ "$OVERALL_FAILED" = "0" ]; then
    echo "TODOS LOS SUITES PASARON"
else
    echo "HAY SUITES CON TESTS FALLIDOS -- revisar arriba"
fi

exit "$OVERALL_FAILED"
