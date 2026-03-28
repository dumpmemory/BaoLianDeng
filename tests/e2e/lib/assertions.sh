#!/bin/bash
# Test assertion helpers for E2E tests

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

assert_eq() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: $description (expected '$expected', got '$actual')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if echo "$haystack" | grep -q "$needle"; then
        echo "  PASS: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: $description (output does not contain '$needle')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_exit_code() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$expected" -eq "$actual" ]; then
        echo "  PASS: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: $description (expected exit code $expected, got $actual)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_nonzero() {
    local description="$1"
    local value="$2"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ -n "$value" ] && [ "$value" != "0" ]; then
        echo "  PASS: $description (value: $value)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL: $description (value is zero or empty: '$value')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

print_results() {
    echo ""
    echo "================================"
    echo "  Results: $TESTS_PASSED/$TESTS_TOTAL passed"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo "  $TESTS_FAILED FAILED"
        echo "================================"
        return 1
    else
        echo "  All tests passed!"
        echo "================================"
        return 0
    fi
}
