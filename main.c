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

    // Extract context_window.used_percentage
    struct json_object *context_window_obj;
    struct json_object *used_pct_obj;
    double used_pct = -1;

    if (json_object_object_get_ex(root, "context_window", &context_window_obj)) {
        if (json_object_object_get_ex(context_window_obj, "used_percentage", &used_pct_obj)) {
            used_pct = json_object_get_double(used_pct_obj);
        }
    }

    // Extract cost.total_cost_usd
    struct json_object *cost_obj;
    struct json_object *total_cost_obj;
    double total_cost = -1;

    if (json_object_object_get_ex(root, "cost", &cost_obj)) {
        if (json_object_object_get_ex(cost_obj, "total_cost_usd", &total_cost_obj)) {
            total_cost = json_object_get_double(total_cost_obj);
        }
    }

    // Format token display as percentage
    char token_display[64];
    if (used_pct >= 0) {
        snprintf(token_display, sizeof(token_display), " | 🎫 %.0f%%", used_pct);
    } else {
        token_display[0] = '\0';
    }

    // Format cost display
    char cost_display[64];
    if (total_cost >= 0) {
        snprintf(cost_display, sizeof(cost_display), " | 💲%.2f", total_cost);
    } else {
        cost_display[0] = '\0';
    }

    // Get basename of current directory
    char *dir_copy = strdup(current_dir_full);
    char *dir_basename = basename(dir_copy);

    // Get git branch
    char *git_branch = read_git_branch();

    // Print formatted output
    printf("[%s] 📁 %s%s%s%s\n", model_name, dir_basename, git_branch, token_display, cost_display);

    // Cleanup
    free(dir_copy);
    json_object_put(root);

    return 0;
}
