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

#define COLOR_GREEN  "\033[32m"
#define COLOR_YELLOW "\033[33m"
#define COLOR_RED    "\033[31m"
#define COLOR_CYAN   "\033[36m"
#define COLOR_RESET  "\033[0m"
#define STYLE_BOLD   "\033[1m"

/* Format token count as compact string: 50000 -> "50k", 1200000 -> "1.2M" */
void format_tokens(int tokens, char *buf, size_t buf_size) {
    if (tokens >= 1000000) {
        double m = tokens / 1000000.0;
        if (m >= 10.0)
            snprintf(buf, buf_size, "%.0fM", m);
        else
            snprintf(buf, buf_size, "%.1fM", m);
    } else if (tokens >= 1000) {
        double k = tokens / 1000.0;
        if (k >= 10.0)
            snprintf(buf, buf_size, "%.0fk", k);
        else
            snprintf(buf, buf_size, "%.1fk", k);
    } else {
        snprintf(buf, buf_size, "%d", tokens);
    }
}

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
            snprintf(branch, sizeof(branch), " | 🌿 " COLOR_GREEN "%s" COLOR_RESET,
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

    // Extract context_window fields
    struct json_object *context_window_obj;
    struct json_object *tmp;
    double used_pct = -1;
    int input_tokens = -1, output_tokens = -1;

    if (json_object_object_get_ex(root, "context_window", &context_window_obj)) {
        if (json_object_object_get_ex(context_window_obj, "used_percentage", &tmp))
            used_pct = json_object_get_double(tmp);
        if (json_object_object_get_ex(context_window_obj, "total_input_tokens", &tmp))
            input_tokens = json_object_get_int(tmp);
        if (json_object_object_get_ex(context_window_obj, "total_output_tokens", &tmp))
            output_tokens = json_object_get_int(tmp);
    }

    // Extract cost fields
    struct json_object *cost_obj;
    double total_cost = -1;
    int lines_added = -1, lines_removed = -1;

    if (json_object_object_get_ex(root, "cost", &cost_obj)) {
        if (json_object_object_get_ex(cost_obj, "total_cost_usd", &tmp))
            total_cost = json_object_get_double(tmp);
        if (json_object_object_get_ex(cost_obj, "total_lines_added", &tmp))
            lines_added = json_object_get_int(tmp);
        if (json_object_object_get_ex(cost_obj, "total_lines_removed", &tmp))
            lines_removed = json_object_get_int(tmp);
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

    // Build line 1 into buffer: [Model] 📁 dir | 🌿 branch | 💲cost
    char line1[512];
    snprintf(line1, sizeof(line1), "[" STYLE_BOLD "%s" COLOR_RESET "] 📁 " COLOR_CYAN "%s" COLOR_RESET "%s%s",
             model_name, dir_basename, git_branch, cost_display);

    // Build line 2 (only if there's data)
    char line2[512];
    int pos = 0;
    int has_content = 0;

    if (used_pct >= 0) {
        const char *pct_color = "";
        const char *pct_reset = "";
        if (used_pct >= 90) {
            pct_color = COLOR_RED;
            pct_reset = COLOR_RESET;
        } else if (used_pct >= 60) {
            pct_color = COLOR_YELLOW;
            pct_reset = COLOR_RESET;
        }
        pos += snprintf(line2 + pos, sizeof(line2) - pos, "%s🎫 %.0f%%%s", pct_color, used_pct, pct_reset);
        has_content = 1;
    }

    if (input_tokens >= 0 && output_tokens >= 0) {
        char in_buf[32], out_buf[32];
        format_tokens(input_tokens, in_buf, sizeof(in_buf));
        format_tokens(output_tokens, out_buf, sizeof(out_buf));
        if (has_content)
            pos += snprintf(line2 + pos, sizeof(line2) - pos, " | ");
        pos += snprintf(line2 + pos, sizeof(line2) - pos, "🔤 %s in / %s out", in_buf, out_buf);
        has_content = 1;
    }

    if (lines_added >= 0 && lines_removed >= 0) {
        if (has_content)
            pos += snprintf(line2 + pos, sizeof(line2) - pos, " | ");
        pos += snprintf(line2 + pos, sizeof(line2) - pos, "✏️ " COLOR_GREEN "+%d" COLOR_RESET " / " COLOR_RED "-%d" COLOR_RESET, lines_added, lines_removed);
        has_content = 1;
    }

    printf("%s\n", line1);
    if (has_content)
        printf("%s\n", line2);

    // Cleanup
    free(dir_copy);
    json_object_put(root);

    return 0;
}
