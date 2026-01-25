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
	@echo "Testing basic functionality..."
	@echo '{"model":{"display_name":"Claude 3.5 Sonnet"},"workspace":{"current_dir":"/home/user/my-project"}}' | ./$(TARGET)
	@echo "\nTesting with current directory..."
	@echo '{"model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"'$$(pwd)'"}}' | ./$(TARGET)
