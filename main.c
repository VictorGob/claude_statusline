#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <json-c/json.h>
#include <libgen.h>
#include <unistd.h>

#define BUFFER_SIZE 4096
#define GIT_HEAD_PATH ".git/HEAD"
#define GIT_REF_PREFIX "ref: refs/heads/"

char* read_git_branch(void) {
    FILE *fp;
    static char branch[256] = "";
    char line[512];

    if (access(GIT_HEAD_PATH, F_OK) != 0) {
        return "";
    }

    fp = fopen(GIT_HEAD_PATH, "r");
    if (!fp) {
        return "";
    }

    if (fgets(line, sizeof(line), fp)) {
        // Remove newline
        line[strcspn(line, "\n")] = 0;

        // Check if it starts with "ref: refs/heads/"
        if (strncmp(line, GIT_REF_PREFIX, strlen(GIT_REF_PREFIX)) == 0) {
            snprintf(branch, sizeof(branch), " | 🌿 %s",
                     line + strlen(GIT_REF_PREFIX));
        }
    }

    fclose(fp);
    return branch;
}

int main(void) {
    char input_buffer[BUFFER_SIZE];
    size_t total_read = 0;
    size_t bytes_read;

    // Read all input from stdin
    while ((bytes_read = fread(input_buffer + total_read, 1,
                                BUFFER_SIZE - total_read - 1, stdin)) > 0) {
        total_read += bytes_read;
        if (total_read >= BUFFER_SIZE - 1) {
            fprintf(stderr, "Error: Input too large\n");
            return 1;
        }
    }
    input_buffer[total_read] = '\0';

    // Parse JSON
    struct json_object *root = json_tokener_parse(input_buffer);
    if (!root) {
        fprintf(stderr, "Error: Failed to parse JSON\n");
        return 1;
    }

    // Extract model.display_name
    struct json_object *model_obj;
    struct json_object *display_name_obj;
    const char *model_name = "Unknown";

    if (json_object_object_get_ex(root, "model", &model_obj)) {
        if (json_object_object_get_ex(model_obj, "display_name", &display_name_obj)) {
            model_name = json_object_get_string(display_name_obj);
        }
    }

    // Extract workspace.current_dir
    struct json_object *workspace_obj;
    struct json_object *current_dir_obj;
    const char *current_dir_full = "";

    if (json_object_object_get_ex(root, "workspace", &workspace_obj)) {
        if (json_object_object_get_ex(workspace_obj, "current_dir", &current_dir_obj)) {
            current_dir_full = json_object_get_string(current_dir_obj);
        }
    }

    // Extract context_window information
    struct json_object *context_window_obj;
    struct json_object *window_size_obj, *input_tokens_obj, *output_tokens_obj;
    int window_size = 0;
    int total_input = 0;
    int total_output = 0;

    if (json_object_object_get_ex(root, "context_window", &context_window_obj)) {
        if (json_object_object_get_ex(context_window_obj, "context_window_size", &window_size_obj)) {
            window_size = json_object_get_int(window_size_obj);
        }
        if (json_object_object_get_ex(context_window_obj, "total_input_tokens", &input_tokens_obj)) {
            total_input = json_object_get_int(input_tokens_obj);
        }
        if (json_object_object_get_ex(context_window_obj, "total_output_tokens", &output_tokens_obj)) {
            total_output = json_object_get_int(output_tokens_obj);
        }
    }

    // Calculate tokens used and remaining
    int tokens_used = total_input + total_output;
    int tokens_remaining = window_size - tokens_used;

    // Format token display (in thousands)
    char token_display[64];
    if (window_size > 0) {
        snprintf(token_display, sizeof(token_display), " | 🎫 %dk/%dk",
                 tokens_remaining / 1000, window_size / 1000);
    } else {
        token_display[0] = '\0';  // Empty if no context window data
    }

    // Get basename of current directory
    char *dir_copy = strdup(current_dir_full);
    char *dir_basename = basename(dir_copy);

    // Get git branch
    char *git_branch = read_git_branch();

    // Print formatted output
    printf("[%s] 📁 %s%s%s\n", model_name, dir_basename, git_branch, token_display);

    // Cleanup
    free(dir_copy);
    json_object_put(root);

    return 0;
}
