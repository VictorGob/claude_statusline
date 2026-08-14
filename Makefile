TARGET = target/release/claude_statusline
TRIPLE := $(shell rustc -vV 2>/dev/null | awk '/^host:/{print $$2}')

.PHONY: all clean test

all: $(TARGET)

# On Linux, link libc statically: it removes the dynamic loader's symbol resolution
# from every spawn, which is where this program's runtime actually goes. Measured at
# ~750us -> ~555us (~26% faster startup) and 81 -> 49 syscalls. opt-level alone moved
# nothing, since there is no hot loop here to optimize. Note hyperfine is unreliable
# at this timescale on a scaling CPU; see the benchmarking note in AGENTS.md.
#
# The explicit --target is required, not cosmetic: without it RUSTFLAGS also reaches
# serde_derive, and a proc-macro cannot be built as a static lib ("does not support
# these crate types"). Passing --target splits host from target artifacts, but also
# relocates the output, hence the copy back to $(TARGET) that statusline.sh expects.
#
# Anything not Linux takes the plain build. macOS has no static libSystem and rustc
# *ignores* crt-static there rather than failing, so probing by trial would silently
# report success while producing an ordinary dynamic binary. target-cpu=native is
# deliberately not used anywhere: it buys nothing measurable on this workload and
# makes the binary SIGILL on older CPUs.
$(TARGET): Cargo.toml src/main.rs
	@if [ "$$(uname -s)" = "Linux" ] && [ -n "$(TRIPLE)" ] && \
	    RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --target $(TRIPLE) 2>/dev/null && \
	    echo '{}' | ./target/$(TRIPLE)/release/claude_statusline >/dev/null 2>&1; then \
		mkdir -p $(dir $(TARGET)); \
		cp target/$(TRIPLE)/release/claude_statusline $(TARGET); \
		echo "Built: static (libc linked in)"; \
	else \
		cargo build --release && echo "Built: default (dynamic libc)"; \
	fi

clean:
	cargo clean

test: $(TARGET)
	@echo "Testing basic functionality (line 1 only)..."
	@echo '{"model":{"display_name":"Claude 3.5 Sonnet"},"workspace":{"current_dir":"/home/user/my-project"}}' | ./$(TARGET)
	@echo ""
	@echo "Testing with all fields (2 lines)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/home/user/project"},"context_window":{"used_percentage":42,"total_input_tokens":50000,"total_output_tokens":12000}}' | ./$(TARGET)
	@echo ""
	@echo "Testing with current directory..."
	@echo '{"model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"'$$(pwd)'"},"context_window":{"used_percentage":75,"total_input_tokens":1200000,"total_output_tokens":300000}}' | ./$(TARGET)
	@echo ""
	@echo "Testing clickable usage link on rate limit countdown..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":50,"total_input_tokens":1000,"total_output_tokens":500},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'$$(( $$(date +%s) + 9000 ))'}}}' | ./$(TARGET) | grep -q '8;;https://claude.ai/settings/usage' && echo "PASS: usage link present" || echo "FAIL: usage link missing"
	@echo ""
	@echo "Testing reasoning effort level..."
	@echo '{"model":{"display_name":"Opus"},"effort":{"level":"high"},"workspace":{"current_dir":"/home/user/project"}}' | ./$(TARGET)
	@echo ""
	@echo "Testing burn rate over budget (1h elapsed, 35% used = 35%/h)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":35,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q '🔥' && echo "PASS: flame shown over 28%/h" || echo "FAIL: flame missing"
	@echo "Testing burn rate on budget (1h elapsed, 10% used = 10%/h)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q '🔥' && echo "FAIL: unexpected flame" || echo "PASS: no flame under 28%/h"
	@echo "Testing yellow band has no flame (1h elapsed, 27% used = 1.35x)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":27,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q '🔥' && echo "FAIL: flame too early in yellow band" || echo "PASS: 27%/h is yellow without flame"
	@echo "Testing exactly-on-budget does not warn (1h elapsed, 20% used = 20%/h)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[33m" && echo "FAIL: on-budget should not be yellow" || echo "PASS: on-budget stays plain"
	@echo "Testing over-budget warns (1h elapsed, 24% used = 24%/h)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[33m" && echo "PASS: yellow at 24%/h" || echo "FAIL: missing yellow"
	@echo "Testing red threshold (1h elapsed, 40% used = 2.00x)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[31m" && echo "PASS: red at 2.00x" || echo "FAIL: missing red"
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q 'dry in' && echo "PASS: dry-in shown at red" || echo "FAIL: dry-in missing"
	@echo "Testing 1.50x is no longer red (1h elapsed, 30% used)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[31m" && echo "FAIL: 1.50x should be yellow" || echo "PASS: 1.50x stays yellow"
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q 'dry in' && echo "FAIL: dry-in below red" || echo "PASS: no dry-in below red"
	@echo "Testing 7d never shows a burn flame (2d elapsed, 45% used)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"seven_day":{"used_percentage":45,"resets_at":'$$(( $$(date +%s) + 432000 ))'}}}' | ./$(TARGET) | grep -q '🔥' && echo "FAIL: 7d should not flag pace" || echo "PASS: 7d has no pace cue"
	@echo "Testing healthy cache ratio is uncolored (60% context, 95k read / 5k write)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60,"current_usage":{"cache_read_input_tokens":95000,"cache_creation_input_tokens":5000}}}' | ./$(TARGET) | grep -q '| 💾 95%' && echo "PASS: cache 95% shown plain" || echo "FAIL: cache ratio missing or colored"
	@echo "Testing cache miss is red (60% context, 20k read / 80k write)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60,"current_usage":{"cache_read_input_tokens":20000,"cache_creation_input_tokens":80000}}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[31m💾 20%" && echo "PASS: red at 20% hit rate" || echo "FAIL: missing red on cache miss"
	@echo "Testing cache indicator hidden below the context floor (10% context)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":10,"current_usage":{"cache_read_input_tokens":20000,"cache_creation_input_tokens":80000}}}' | ./$(TARGET) | grep -q '💾' && echo "FAIL: cold start should not flag a miss" || echo "PASS: no cache cue under 30% context"
	@echo "Testing cache indicator hidden when current_usage is null (post-/compact)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60,"current_usage":null}}' | ./$(TARGET) | grep -q '💾' && echo "FAIL: null usage should render nothing" || echo "PASS: no cache cue without usage"
	@echo "Testing session age warns and shows activity (5h02m wall, 5m API)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_duration_ms":18120000,"total_api_duration_ms":300000}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[33m5h02m" && echo "PASS: yellow age past 4h" || echo "FAIL: missing yellow age"
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_duration_ms":18120000,"total_api_duration_ms":300000}}' | ./$(TARGET) | grep -q '⚡2%' && echo "PASS: activity shown on long session" || echo "FAIL: activity missing"
	@echo "Testing a short session shows age but no activity (10m wall)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_duration_ms":600000,"total_api_duration_ms":120000}}' | ./$(TARGET) | grep -q '⏳ 10m' && echo "PASS: 10m age shown plain" || echo "FAIL: age missing"
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_duration_ms":600000,"total_api_duration_ms":120000}}' | ./$(TARGET) | grep -q '⚡' && echo "FAIL: activity meaningless under 1h" || echo "PASS: no activity cue under 1h"
	@echo "Testing activity clamps at 100% (parallel subagents sum past wall clock)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_duration_ms":7200000,"total_api_duration_ms":18000000}}' | ./$(TARGET) | grep -q '⚡100%' && echo "PASS: activity clamped to 100%" || echo "FAIL: activity exceeded 100%"
