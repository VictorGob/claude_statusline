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
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":35,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q '🔥' && echo "PASS: flame shown over 25%/h" || echo "FAIL: flame missing"
	@echo "Testing burn rate on budget (1h elapsed, 10% used = 10%/h)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":'$$(( $$(date +%s) + 14400 ))'}}}' | ./$(TARGET) | grep -q '🔥' && echo "FAIL: unexpected flame" || echo "PASS: no flame under 25%/h"
