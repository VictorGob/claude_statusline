TARGET = target/release/claude_statusline

.PHONY: all clean test

all: $(TARGET)

$(TARGET): Cargo.toml src/main.rs
	cargo build --release

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
