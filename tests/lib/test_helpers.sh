#!/usr/bin/env bash
# Helpers mínimos de aserción para los tests de este proyecto.
#
# Deliberadamente sin bats/shunit2 ni ningún otro framework: el resto del
# proyecto ya sigue la filosofía de "sin dependencias extra" (ver
# docs/ARCHITECTURE.md, "No Python dependency" -- todo con sed/awk/grep), y
# el entorno donde se escribió esto no tenía ninguno instalado. Un puñado de
# funciones de assert en bash puro alcanza para lo que hay que probar acá.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_SUITE=""

suite() {
    CURRENT_SUITE="$1"
    echo
    echo "== $CURRENT_SUITE =="
}

_test_ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  [ok] $1"
}

_test_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  [FAIL] $1"
}

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [ "$actual" = "$expected" ]; then
        _test_ok "$desc"
    else
        _test_fail "$desc -- esperado: [$expected] obtenido: [$actual]"
    fi
}

assert_ne() {
    local actual="$1" not_expected="$2" desc="$3"
    if [ "$actual" != "$not_expected" ]; then
        _test_ok "$desc"
    else
        _test_fail "$desc -- no debía ser [$not_expected]"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    case "$haystack" in
        *"$needle"*) _test_ok "$desc" ;;
        *) _test_fail "$desc -- no se encontró [$needle]" ;;
    esac
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    case "$haystack" in
        *"$needle"*) _test_fail "$desc -- contiene [$needle] y no debía" ;;
        *) _test_ok "$desc" ;;
    esac
}

# assert_exit_code EXPECTED DESC CMD... -- corre CMD (con sus args) en un
# subshell y compara su código de salida contra EXPECTED. El subshell hereda
# las funciones ya definidas en el script de test que llama a esto (es bash
# normal: un '( ... )' ve las funciones del shell que lo contiene), así que
# alcanza con pasar el nombre de una función real, no hace falta re-fuentear
# nada.
assert_exit_code() {
    local expected="$1" desc="$2"
    shift 2
    local out actual
    out="$(mktemp)"
    # El 'if' es a propósito: es la única forma de que un comando que falla
    # no dispare el 'set -e' del script de test que llama a esto -- sin el
    # 'if', un CMD que devuelve distinto de 0 aborta toda la suite en vez de
    # dejar que esta función reporte el resultado como un test más.
    if ( "$@" ) >"$out" 2>&1; then
        actual=0
    else
        actual=$?
    fi
    if [ "$actual" = "$expected" ]; then
        _test_ok "$desc"
    else
        _test_fail "$desc -- esperado exit $expected, obtenido $actual. Salida: $(cat "$out")"
    fi
    rm -f "$out"
}

# run_and_capture OUT_VAR CODE_VAR CMD... -- corre CMD, guarda su salida
# combinada (stdout+stderr) en OUT_VAR y su exit code en CODE_VAR, sin
# disparar el 'set -e' del script que llama a esto (mismo motivo que en
# assert_exit_code: un CMD con exit != 0 asignado vía "$(...)" mata la
# suite entera bajo 'set -Eeuo pipefail' si no se guarda detrás de un 'if').
run_and_capture() {
    local out_var="$1" code_var="$2"
    shift 2
    local tmp code
    tmp="$(mktemp)"
    if "$@" >"$tmp" 2>&1; then
        code=0
    else
        code=$?
    fi
    printf -v "$out_var" '%s' "$(cat "$tmp")"
    printf -v "$code_var" '%s' "$code"
    rm -f "$tmp"
}

print_summary() {
    echo
    echo "=================================================================="
    echo "$CURRENT_SUITE (última suite) -- total acumulado: $TESTS_RUN, fallidos: $TESTS_FAILED"
    echo "=================================================================="
    [ "$TESTS_FAILED" -eq 0 ]
}
