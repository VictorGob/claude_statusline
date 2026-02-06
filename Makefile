CC = gcc
CFLAGS = -Wall -Wextra -std=c99
LIBS = -ljson-c
TARGET = claude_statusline
SRC = main.c

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) $(LIBS)

clean:
	rm -f $(TARGET)

test: $(TARGET)
	@echo "Testing basic functionality (line 1 only)..."
	@echo '{"model":{"display_name":"Claude 3.5 Sonnet"},"workspace":{"current_dir":"/home/user/my-project"}}' | ./$(TARGET)
	@echo ""
	@echo "Testing with all fields (2 lines)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/home/user/project"},"cost":{"total_cost_usd":0.05,"total_lines_added":156,"total_lines_removed":23},"context_window":{"used_percentage":42,"total_input_tokens":50000,"total_output_tokens":12000}}' | ./$(TARGET)
	@echo ""
	@echo "Testing with current directory..."
	@echo '{"model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"'$$(pwd)'"},"context_window":{"used_percentage":75,"total_input_tokens":1200000,"total_output_tokens":300000},"cost":{"total_cost_usd":1.23,"total_lines_added":42,"total_lines_removed":10}}' | ./$(TARGET)
