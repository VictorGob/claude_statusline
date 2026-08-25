TARGET = target/release/claude_statusline
TRIPLE := $(shell rustc -vV 2>/dev/null | awk '/^host:/{print $$2}')

.PHONY: all clean test

all: $(TARGET)

# On Linux, link libc statically: it removes the dynamic loader's symbol resolution
# from every spawn, which is where this program's runtime actually goes. Measured at
# ~750us -> ~555us (~26% faster startup) and 81 -> 49 syscalls. opt-level alone moved
# nothing *on Linux*, since there is no hot loop here to optimize -- but it is not inert
# everywhere: Cargo.toml sets opt-level="z" for a measured startup win on Windows, where
# the image is mapped on every spawn. Note hyperfine is unreliable at this timescale on a
# scaling CPU; see the benchmarking note in AGENTS.md.
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
$(TARGET): Cargo.toml src/main.rs build.rs
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

# Unit tests first: they cover the threshold boundaries the smoke assertions below can
# only sample, and they fail in milliseconds without spawning a process per case.
test: $(TARGET)
	@echo "Running unit tests..."
	cargo test --quiet
	@echo ""
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
	@echo "Testing the gap gate surfaces an early overspend (7m elapsed, 5% used = 2.14x)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":'$$(( $$(date +%s) + 17580 ))'}}}' | ./$(TARGET) | grep -q 'dry in' && echo "PASS: red 7m in, once past the 6m floor" || echo "FAIL: early overspend still blacked out"
	@echo "Testing sub-point drift stays plain (16m elapsed, 6.3% used = 1.18x, gap 0.97)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":6.3,"resets_at":'$$(( $$(date +%s) + 17040 ))'}}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[33m" && echo "FAIL: under a point of lead should not warn" || echo "PASS: 1.18x under the gap stays plain"
	@echo "Testing 7d never shows a burn flame (2d elapsed, 45% used)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"seven_day":{"used_percentage":45,"resets_at":'$$(( $$(date +%s) + 432000 ))'}}}' | ./$(TARGET) | grep -q '🔥' && echo "FAIL: 7d should not flag pace" || echo "PASS: 7d has no pace cue"
	@echo "Testing healthy cache ratio is uncolored (60% context, 95k read / 5k write)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60,"current_usage":{"cache_read_input_tokens":95000,"cache_creation_input_tokens":5000}}}' | ./$(TARGET) | grep -q '| 💾 95%' && echo "PASS: cache 95% shown plain" || echo "FAIL: cache ratio missing or colored"
	@echo "Testing cache miss is red (60% context, 20k read / 80k write)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60,"current_usage":{"cache_read_input_tokens":20000,"cache_creation_input_tokens":80000}}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[31m💾 20%" && echo "PASS: red at 20% hit rate" || echo "FAIL: missing red on cache miss"
	@echo "Testing the cache indicator is shown from the first turn (10% context)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":10,"current_usage":{"cache_read_input_tokens":20000,"cache_creation_input_tokens":80000}}}' | ./$(TARGET) | grep -q '💾 20%' && echo "PASS: cold-start miss is visible" || echo "FAIL: cache cue hidden at low context"
	@echo "Testing a large cache write is flagged as a rebuild (80k written)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":10,"current_usage":{"cache_read_input_tokens":20000,"cache_creation_input_tokens":80000}}}' | ./$(TARGET) | grep -q '🧊80k' && echo "PASS: rebuild marker shows the size written" || echo "FAIL: rebuild marker missing"
	@echo "Testing a small cache write is not flagged (5k written)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60,"current_usage":{"cache_read_input_tokens":95000,"cache_creation_input_tokens":5000}}}' | ./$(TARGET) | grep -q '🧊' && echo "FAIL: a top-up is not a rebuild" || echo "PASS: no marker under 50k written"
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
	@echo ""
	@echo "Testing context shows absolute tokens beside the percentage..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42,"total_input_tokens":84000}}' | ./$(TARGET) | grep -q '🎫 42% (84k)' && echo "PASS: token count shown" || echo "FAIL: token count missing"
	@echo "Testing the percentage stands alone when no token count is sent..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42}}' | ./$(TARGET) | grep -q '🎫 42%$$' && echo "PASS: bare percentage unchanged" || echo "FAIL: bare percentage altered"
	@echo "Testing the size ladder: 199k at 30% is under the warn step..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":30,"total_input_tokens":199000}}' | ./$(TARGET) | grep -q '^🎫 30% (199k)' && echo "PASS: 199k at 30% stays plain" || echo "FAIL: 199k should be uncoloured at 30%"
	@echo "Testing the size ladder: 200k at 30% warns where the percentage sees nothing..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":30,"total_input_tokens":200000}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[33m🎫" && echo "PASS: yellow at 200k" || echo "FAIL: no warn step at 200k"
	@echo "Testing the size ladder: 300k at 30% is red..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":30,"total_input_tokens":300000}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[31m🎫" && echo "PASS: red at 300k" || echo "FAIL: no red at 300k"
	@echo "Testing the size ladder: 500k at 50% is bold red..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":50,"total_input_tokens":500000}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[1;31m🎫" && echo "PASS: bold red at 500k" || echo "FAIL: no critical step at 500k"
	@echo "Testing the louder ladder wins: 184k at 92% is red from the percentage..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":92,"total_input_tokens":184000}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[31m🎫" && echo "PASS: a full window still colours under the warn step" || echo "FAIL: size-wins-outright regression"
	@echo "Testing a full small window is not the critical step (95% of 50k)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":95,"total_input_tokens":50000}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[1;31m🎫" && echo "FAIL: a full small window is not critical" || echo "PASS: 95% of 50k is red, not bold"
	@echo "Testing a missing token count falls back to used_percentage (92%, no tokens)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":92}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[31m🎫" && echo "PASS: falls back to plain red" || echo "FAIL: fallback colouring lost"
	@echo "Testing the 5h bar keeps the old bands at 75% (pct_color untouched)..."
	@echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":75}}}' | ./$(TARGET) | grep -q "$$(printf '\033')\[31m" && echo "FAIL: quota bars moved with the context bands" || echo "PASS: 75% quota is still yellow"
	@echo ""
	@echo "Testing a detached HEAD shows the short SHA..."
	@tmp=$$(mktemp -d) && mkdir -p $$tmp/.git && echo '1234567890abcdef1234567890abcdef12345678' > $$tmp/.git/HEAD && \
	  echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' | (cd $$tmp && $(CURDIR)/$(TARGET)) | grep -q '@1234567' \
	  && echo "PASS: detached HEAD shows @1234567" || echo "FAIL: detached HEAD did not render the short SHA"; rm -rf $$tmp
	@echo "Testing a worktree gitdir pointer renders no branch..."
	@tmp=$$(mktemp -d) && mkdir -p $$tmp/.git && echo 'gitdir: /some/worktree/path' > $$tmp/.git/HEAD && \
	  echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' | (cd $$tmp && $(CURDIR)/$(TARGET)) | grep -q '🌿' \
	  && echo "FAIL: gitdir pointer rendered a branch" || echo "PASS: gitdir pointer stays silent"; rm -rf $$tmp
	@echo "Testing a real worktree (.git is a FILE) falls back to the worktree name..."
	@tmp=$$(mktemp -d) && echo 'gitdir: /some/repo/.git/worktrees/feat' > $$tmp/.git && \
	  echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp","git_worktree":"my-feature"}}' | (cd $$tmp && $(CURDIR)/$(TARGET)) | grep -q '🌿 .*my-feature' \
	  && echo "PASS: worktree name shown when HEAD is unreadable" || echo "FAIL: worktree fallback missing"; rm -rf $$tmp
	@echo "Testing a worktree-shaped .git without the field stays silent..."
	@tmp=$$(mktemp -d) && echo 'gitdir: /some/repo/.git/worktrees/feat' > $$tmp/.git && \
	  echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' | (cd $$tmp && $(CURDIR)/$(TARGET)) | grep -q '🌿' \
	  && echo "FAIL: rendered a branch with nothing to render" || echo "PASS: no field, no segment"; rm -rf $$tmp
	@echo "Testing a plain non-git folder is unaffected by the fallback..."
	@tmp=$$(mktemp -d) && \
	  echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' | (cd $$tmp && $(CURDIR)/$(TARGET)) | grep -q '🌿' \
	  && echo "FAIL: non-git folder rendered a branch" || echo "PASS: non-git folder stays silent"; rm -rf $$tmp
	@echo "Testing a real branch wins over the worktree field (fast path first)..."
	@tmp=$$(mktemp -d) && mkdir -p $$tmp/.git && echo 'ref: refs/heads/real-branch' > $$tmp/.git/HEAD && \
	  echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp","git_worktree":"ignored-name"}}' | (cd $$tmp && $(CURDIR)/$(TARGET)) | grep -q 'ignored-name' \
	  && echo "FAIL: fallback overrode a readable HEAD" || echo "PASS: .git/HEAD takes precedence"; rm -rf $$tmp
	@echo "Testing a normal ref still renders the branch name..."
	@tmp=$$(mktemp -d) && mkdir -p $$tmp/.git && echo 'ref: refs/heads/some-branch' > $$tmp/.git/HEAD && \
	  echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' | (cd $$tmp && $(CURDIR)/$(TARGET)) | grep -q 'some-branch' \
	  && echo "PASS: ref renders branch name" || echo "FAIL: ref did not render the branch name"; rm -rf $$tmp
	@echo ""
	@echo "Testing --version prints name, semver and build SHA..."
	@./$(TARGET) --version | grep -qE '^claude_statusline [0-9]+\.[0-9]+\.[0-9]+ \(.+\)$$' && echo "PASS: version format" || echo "FAIL: bad version format"
	@echo "Testing -V matches --version..."
	@[ "$$(./$(TARGET) --version)" = "$$(./$(TARGET) -V)" ] && echo "PASS: -V is an alias" || echo "FAIL: -V differs from --version"
	@echo "Testing --version exits 0..."
	@./$(TARGET) --version >/dev/null 2>&1 && echo "PASS: exit 0" || echo "FAIL: non-zero exit"
	@echo "Testing --version returns with no stdin attached (must not block)..."
	@./$(TARGET) --version </dev/null >/dev/null 2>&1 && echo "PASS: no stdin needed" || echo "FAIL: --version failed without stdin"
	@echo "Testing an unrecognized argument still renders a statusline..."
	@[ "$$(echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' | ./$(TARGET) --not-a-flag)" = "$$(echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' | ./$(TARGET))" ] && echo "PASS: unknown arg ignored" || echo "FAIL: unknown arg changed the output"
