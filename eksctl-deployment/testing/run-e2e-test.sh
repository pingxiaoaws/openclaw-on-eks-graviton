#!/usr/bin/env bash

##################################################
# OpenClaw on EKS - End-to-End Test Runner
##################################################
#
# This script orchestrates the complete E2E test
# of the OpenClaw deployment on EKS, from cluster
# creation to cleanup.
#
# Usage:
#   ./run-e2e-test.sh [standard|kata]
#
# The script will:
# 1. Run all deployment scripts in sequence
# 2. Execute validation checks after each phase
# 3. Generate a test report with results
# 4. Optionally run cleanup
#
##################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_MODE="${1:-standard}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="./reports/test-report-${TEST_MODE}-${TIMESTAMP}.md"
SCRIPTS_DIR="../scripts"
TEST_DIR="$(pwd)"

# Create reports directory
mkdir -p ./reports

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅${NC} $1"
}

log_error() {
    echo -e "${RED}❌${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠️ ${NC} $1"
}

# Banner
print_banner() {
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║        OpenClaw on EKS - End-to-End Test Suite                ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
EOF
}

# Initialize test report
init_report() {
    cat > "$REPORT_FILE" << EOF
# OpenClaw on EKS - E2E Test Report

**Test Mode**: ${TEST_MODE}
**Date**: $(date)
**Tester**: $(whoami)
**Test ID**: ${TIMESTAMP}

## Test Configuration

- **Cluster Mode**: ${TEST_MODE}
- **Cluster Name**: (will be populated after Phase 1)
- **AWS Region**: (will be populated after Phase 1)
- **Start Time**: $(date)

---

EOF
    log_success "Test report initialized: $REPORT_FILE"
}

# Add phase result to report
add_phase_result() {
    local phase=$1
    local status=$2
    local duration=$3
    local notes=$4

    cat >> "$REPORT_FILE" << EOF
### Phase $phase

- **Status**: $status
- **Duration**: $duration seconds ($((duration / 60)) min $((duration % 60)) sec)
- **Timestamp**: $(date)
- **Notes**: $notes

EOF
}

# Validate prerequisites
validate_prerequisites() {
    log_info "Validating prerequisites..."

    local missing_tools=()

    if ! command -v eksctl &> /dev/null; then
        missing_tools+=("eksctl")
    fi

    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi

    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi

    if ! command -v docker &> /dev/null; then
        missing_tools+=("docker")
    fi

    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install missing tools and try again"
        exit 1
    fi

    log_success "All required tools installed"
}

# Phase 1: EKS Cluster Creation
run_phase1() {
    log_info "=== Phase 1: EKS Cluster Creation ==="
    local start_time=$(date +%s)

    cd "$SCRIPTS_DIR"

    if [ "$TEST_MODE" = "kata" ]; then
        echo "2" | ./01-deploy-eks-cluster.sh
    else
        echo "1" | ./01-deploy-eks-cluster.sh
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    cd "$TEST_DIR"

    # Run validation
    if ./validate-phase1.sh; then
        log_success "Phase 1 completed successfully"
        add_phase_result "1: EKS Cluster Creation" "✅ PASS" "$duration" "Cluster created and validated"
        return 0
    else
        log_error "Phase 1 validation failed"
        add_phase_result "1: EKS Cluster Creation" "❌ FAIL" "$duration" "Validation failed - see logs"
        return 1
    fi
}

# Phase 2: Infrastructure Controllers
run_phase2() {
    log_info "=== Phase 2: Infrastructure Controllers ==="
    local start_time=$(date +%s)

    cd "$SCRIPTS_DIR"
    ./02-deploy-controllers.sh

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    cd "$TEST_DIR"

    # Run validation
    if ./validate-phase2.sh; then
        log_success "Phase 2 completed successfully"
        add_phase_result "2: Infrastructure Controllers" "✅ PASS" "$duration" "All controllers deployed and validated"
        return 0
    else
        log_error "Phase 2 validation failed"
        add_phase_result "2: Infrastructure Controllers" "❌ FAIL" "$duration" "Validation failed - see logs"
        return 1
    fi
}

# Phase 3: Verification
run_phase3() {
    log_info "=== Phase 3: Infrastructure Verification ==="
    local start_time=$(date +%s)

    cd "$SCRIPTS_DIR"
    ./03-verify-deployment.sh

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    cd "$TEST_DIR"

    log_success "Phase 3 completed successfully"
    add_phase_result "3: Infrastructure Verification" "✅ PASS" "$duration" "All infrastructure checks passed"
    return 0
}

# Phase 4: Application Stack
run_phase4() {
    log_info "=== Phase 4: Application Stack Deployment ==="
    local start_time=$(date +%s)

    cd "$SCRIPTS_DIR"
    ./04-deploy-application-stack.sh

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    cd "$TEST_DIR"

    # Run validation
    if ./validate-phase4.sh; then
        log_success "Phase 4 completed successfully"
        add_phase_result "4: Application Stack" "✅ PASS" "$duration" "All application components deployed and validated"
        return 0
    else
        log_error "Phase 4 validation failed"
        add_phase_result "4: Application Stack" "❌ FAIL" "$duration" "Validation failed - see logs"
        return 1
    fi
}

# Phase 5: End-User Access Testing
run_phase5() {
    log_info "=== Phase 5: End-User Access Testing ==="
    local start_time=$(date +%s)

    if ./test-user-access.sh; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_success "Phase 5 completed successfully"
        add_phase_result "5: End-User Access" "✅ PASS" "$duration" "Test user created, CloudFront accessible"
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_error "Phase 5 failed"
        add_phase_result "5: End-User Access" "❌ FAIL" "$duration" "User access testing failed"
        return 1
    fi
}

# Phase 6: OpenClaw Instance Creation
run_phase6() {
    log_info "=== Phase 6: OpenClaw Instance Creation ==="
    local start_time=$(date +%s)

    if ./create-test-instance.sh "$TEST_MODE"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_success "Phase 6 completed successfully"
        add_phase_result "6: OpenClaw Instance" "✅ PASS" "$duration" "Instance created and validated"
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_error "Phase 6 failed"
        add_phase_result "6: OpenClaw Instance" "❌ FAIL" "$duration" "Instance creation failed"
        return 1
    fi
}

# Phase 7: Cleanup
run_phase7() {
    log_info "=== Phase 7: Cleanup ==="

    log_warning "This will DELETE all resources created during the test"
    read -p "Do you want to run cleanup? (yes/no): " -r
    echo

    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Skipping cleanup - resources remain in AWS"
        add_phase_result "7: Cleanup" "⏭️  SKIPPED" "0" "User chose to keep resources"
        return 0
    fi

    local start_time=$(date +%s)

    cd "$SCRIPTS_DIR"
    ./06-cleanup-all-resources.sh

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    cd "$TEST_DIR"

    log_success "Phase 7 completed successfully"
    add_phase_result "7: Cleanup" "✅ PASS" "$duration" "All resources cleaned up"
    return 0
}

# Finalize report
finalize_report() {
    local end_time=$(date)
    local total_duration=$1

    cat >> "$REPORT_FILE" << EOF

---

## Test Summary

- **End Time**: $end_time
- **Total Duration**: $total_duration seconds ($((total_duration / 60)) minutes)
- **Overall Status**: ${2}

## Cluster Information

\`\`\`bash
# Get cluster info
kubectl cluster-info
kubectl get nodes -o wide
kubectl get deployment -n openclaw-provisioning openclaw-provisioning
\`\`\`

## Next Steps

${3}

---

**Report Generated**: $(date)
**Report File**: $REPORT_FILE
EOF

    log_success "Test report finalized: $REPORT_FILE"
}

# Main test execution
main() {
    print_banner

    log_info "Starting E2E test in $TEST_MODE mode"

    # Validate mode
    if [[ "$TEST_MODE" != "standard" && "$TEST_MODE" != "kata" ]]; then
        log_error "Invalid test mode: $TEST_MODE"
        log_info "Usage: $0 [standard|kata]"
        exit 1
    fi

    # Initialize
    validate_prerequisites
    init_report

    local test_start=$(date +%s)
    local failed=0

    # Run phases
    run_phase1 || failed=1
    if [ $failed -eq 0 ]; then
        run_phase2 || failed=1
    fi

    if [ $failed -eq 0 ]; then
        run_phase3 || failed=1
    fi

    if [ $failed -eq 0 ]; then
        run_phase4 || failed=1
    fi

    if [ $failed -eq 0 ]; then
        run_phase5 || failed=1
    fi

    if [ $failed -eq 0 ]; then
        run_phase6 || failed=1
    fi

    # Always offer cleanup (even if test failed)
    run_phase7

    # Finalize report
    local test_end=$(date +%s)
    local total_duration=$((test_end - test_start))

    if [ $failed -eq 0 ]; then
        finalize_report "$total_duration" "✅ ALL TESTS PASSED" "Test completed successfully. Review report for details."
        log_success "╔════════════════════════════════════════════╗"
        log_success "║     ✅ ALL TESTS PASSED                    ║"
        log_success "╚════════════════════════════════════════════╝"
        log_info "Test report: $REPORT_FILE"
        exit 0
    else
        finalize_report "$total_duration" "❌ TEST FAILED" "Review failed phases above. Check validation logs for details."
        log_error "╔════════════════════════════════════════════╗"
        log_error "║     ❌ TEST FAILED                         ║"
        log_error "╚════════════════════════════════════════════╝"
        log_info "Test report: $REPORT_FILE"
        exit 1
    fi
}

# Run main
main
