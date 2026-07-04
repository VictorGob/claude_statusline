#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <json-c/json.h>
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

/* Format "resets in" hyperlinked suffix, e.g. ", resets in 2h30m". Empty if resets_at not set/past. */
void format_reset_suffix(int64_t resets_at, char *buf, size_t buf_size) {
    buf[0] = '\0';
    long remaining = (resets_at > 0) ? (long)(resets_at - (int64_t)time(NULL)) : -1;
    if (remaining <= 0)
        return;

    long days = remaining / 86400;
    long h = (remaining % 86400) / 3600;
    long m = (remaining % 3600) / 60;

    if (days > 0)
        snprintf(buf, buf_size, ", \033]8;;https://claude.ai/settings/usage\033\\resets in %ldd%ldh\033]8;;\033\\", days, h);
    else if (h > 0)
        snprintf(buf, buf_size, ", \033]8;;https://claude.ai/settings/usage\033\\resets in %ldh%ldm\033]8;;\033\\", h, m);
    else
        snprintf(buf, buf_size, ", \033]8;;https://claude.ai/settings/usage\033\\resets in %ldm\033]8;;\033\\", m);
}

char* read_git_branch(void) {
    FILE *fp;
    static char branch[544] = "";
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

    if (json_object_object_get_ex(root, "context_window", &context_window_obj)) {
        if (json_object_object_get_ex(context_window_obj, "used_percentage", &tmp))
            used_pct = json_object_get_double(tmp);
    }

    // Extract rate_limits.five_hour and rate_limits.seven_day fields
    struct json_object *rate_limits_obj, *five_hour_obj, *seven_day_obj;
    double five_hour_pct = -1, seven_day_pct = -1;
    int64_t five_hour_resets_at = -1, seven_day_resets_at = -1;

    if (json_object_object_get_ex(root, "rate_limits", &rate_limits_obj)) {
        if (json_object_object_get_ex(rate_limits_obj, "five_hour", &five_hour_obj)) {
            if (json_object_object_get_ex(five_hour_obj, "used_percentage", &tmp))
                five_hour_pct = json_object_get_double(tmp);
            if (json_object_object_get_ex(five_hour_obj, "resets_at", &tmp))
                five_hour_resets_at = json_object_get_int64(tmp);
        }
        if (json_object_object_get_ex(rate_limits_obj, "seven_day", &seven_day_obj)) {
            if (json_object_object_get_ex(seven_day_obj, "used_percentage", &tmp))
                seven_day_pct = json_object_get_double(tmp);
            if (json_object_object_get_ex(seven_day_obj, "resets_at", &tmp))
                seven_day_resets_at = json_object_get_int64(tmp);
        }
    }

    // Get basename of current directory
    const char *dir_basename = strrchr(current_dir_full, '/');
    dir_basename = dir_basename ? dir_basename + 1 : current_dir_full;

    // Get git branch
    char *git_branch = read_git_branch();

    // Build line 1 into buffer: [Model] 📁 dir | 🌿 branch
    char line1[512];
    snprintf(line1, sizeof(line1), STYLE_BOLD "%s" COLOR_RESET " | 📁 " COLOR_CYAN "%s" COLOR_RESET "%s",
             model_name, dir_basename, git_branch);

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

    if (five_hour_pct >= 0) {
        const char *rl_color = "";
        const char *rl_reset = "";
        if (five_hour_pct >= 90) {
            rl_color = COLOR_RED;
            rl_reset = COLOR_RESET;
        } else if (five_hour_pct >= 60) {
            rl_color = COLOR_YELLOW;
            rl_reset = COLOR_RESET;
        }
        if (has_content)
            pos += snprintf(line2 + pos, sizeof(line2) - pos, " | ");

        char reset_buf[128];
        format_reset_suffix(five_hour_resets_at, reset_buf, sizeof(reset_buf));
        pos += snprintf(line2 + pos, sizeof(line2) - pos, "⏱️ 5h: %s%.0f%%%s%s",
                        rl_color, five_hour_pct, rl_reset, reset_buf);
        has_content = 1;
    }

    if (seven_day_pct >= 0) {
        const char *rl_color = "";
        const char *rl_reset = "";
        if (seven_day_pct >= 90) {
            rl_color = COLOR_RED;
            rl_reset = COLOR_RESET;
        } else if (seven_day_pct >= 60) {
            rl_color = COLOR_YELLOW;
            rl_reset = COLOR_RESET;
        }
        if (has_content)
            pos += snprintf(line2 + pos, sizeof(line2) - pos, " | ");

        char reset_buf[128];
        format_reset_suffix(seven_day_resets_at, reset_buf, sizeof(reset_buf));
        pos += snprintf(line2 + pos, sizeof(line2) - pos, "📅 7d: %s%.0f%%%s%s",
                        rl_color, seven_day_pct, rl_reset, reset_buf);
        has_content = 1;
    }

    printf("%s\n", line1);
    if (has_content)
        printf("%s\n", line2);

    // Cleanup
    json_object_put(root);

    return 0;
}
