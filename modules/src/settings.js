(function () {
  "use strict";
  function applyDoc(doc, ids) {
    ids.forEach(function (id) {
      var from = doc.getElementById(id);
      var to = document.getElementById(id);
      if (from && to) { to.replaceWith(document.importNode(from, true)); }
    });
  }
  function parseHTML(text) {
    return new DOMParser().parseFromString(text, "text/html");
  }

  // Shared writer for the Danger-zone progress spans (#restart-status,
  // #update-status): set the data-state colour + text, optionally
  // appending a trailing link.
  function setStatus(el, state, text, linkText, href) {
    if (!el) { return; }
    el.setAttribute("data-state", state);
    el.textContent = text;
    if (linkText && href) {
      var link = document.createElement("a");
      link.href = href;
      link.textContent = linkText;
      link.rel = "noreferrer";
      el.appendChild(document.createTextNode(" "));
      el.appendChild(link);
    }
  }
  // One GET of the JSON progress feed; resolves null on any error so
  // callers treat "daemon briefly gone" (mid-rebuild) like any other
  // not-yet-ready poll rather than a hard failure.
  function fetchStatus(url) {
    return fetch(url, { headers: { "Accept": "application/json" } })
      .then(function (r) { if (!r.ok) { throw new Error(); } return r.json(); })
      .catch(function () { return null; });
  }
  // Re-fetch the current page and patch the live session list/tabs, so
  // the visible list tracks a restart even when nothing was "starting"
  // at submit time (which is what otherwise gates schedulePoll).
  function pollPageOnce() {
    return fetch(window.location.pathname + window.location.search)
      .then(function (r) { return r.text(); })
      .then(function (t) { applyDoc(parseHTML(t), ["sessions-list", "tab-bar"]); wsSync(); })
      .catch(function () {});
  }

  // After "Update box": watch the update oneshot from `baseline` (its
  // start time before we triggered) until a strictly newer run
  // finishes. The rebuild may restart this daemon, so a failed fetch is
  // "still rebuilding", not an error.
  function watchUpdate(url, baseline, rev0) {
    var el = document.getElementById("update-status");
    if (!el) { return; }
    var tries = 0, MAX = 300;             // ~12 min at 2.5s
    setStatus(el, "checking", "Starting update…");
    (function tick() {
      if (tries++ > MAX) {
        setStatus(el, "blocked", "Update still running — check the box shortly.");
        return;
      }
      fetchStatus(url).then(function (s) {
        if (!s || !s.update) {           // daemon switching, or no unit to watch
          setStatus(el, "checking", "Rebuilding the system…");
          window.setTimeout(tick, 2500);
          return;
        }
        var u = s.update;
        if (u.active === "activating" || u.active === "active") {
          setStatus(el, "available", "Update in progress…");
          window.setTimeout(tick, 2500);
          return;
        }
        if (u.since > baseline) {        // a newer run started and is no longer active → done
          if (u.active === "failed" || u.result !== "success") {
            setStatus(el, "blocked", "Update failed — check the update service journal.");
          } else if (s.rev && rev0 && s.rev !== rev0) {
            var repo = el.getAttribute("data-repo");
            var short = s.rev.slice(0, 12);
            if (repo) {
              var href = "https://github.com/" +
                repo.split("/").map(encodeURIComponent).join("/") +
                "/commit/" + encodeURIComponent(s.rev);
              setStatus(el, "current", "Updated — now at " + short + ".", "View commit", href);
            } else {
              setStatus(el, "current", "Updated — now at " + short + ".");
            }
          } else {
            setStatus(el, "current", "Update finished.");
          }
          return;
        }
        setStatus(el, "checking", "Starting update…");   // triggered, run not registered yet
        window.setTimeout(tick, 2500);
      });
    })();
  }
  // After "Restart all": watch the live session count recover. Wait to
  // see it dip below the configured count before declaring success, so
  // the pre-kill "all live" state isn't misread as "done".
  function watchRestart(url) {
    var el = document.getElementById("restart-status");
    if (!el) { return; }
    var dipped = false, tries = 0, MAX = 40;   // ~100s at 2.5s
    setStatus(el, "checking", "Restarting sessions…");
    (function tick() {
      if (tries++ > MAX) {
        setStatus(el, "blocked", "Still restarting — check the session list.");
        return;
      }
      pollPageOnce();
      fetchStatus(url).then(function (s) {
        if (!s || !s.sessions) { window.setTimeout(tick, 2500); return; }
        var conf = s.sessions.configured, live = s.sessions.live;
        if (conf === 0) { setStatus(el, "current", "Restart requested."); return; }
        if (live < conf) { dipped = true; }
        if (dipped && live >= conf) {
          setStatus(el, "current", "All sessions restarted.");
          return;
        }
        window.setTimeout(tick, 2500);
      });
    })();
  }

  // The page itself never waits on GitHub. Once it is visible, make a
  // single compare request: GitHub reports whether repository HEAD is
  // ahead of the running revision and provides the commit count. The
  // rendered compare link remains useful if the request is blocked or
  // rate-limited.
  function checkForUpdate() {
    var el = document.getElementById("update-status");
    if (!el) { return; }
    var repo = el.getAttribute("data-repo");
    var rev = el.getAttribute("data-rev");
    var fallback = el.getAttribute("data-compare-url");
    if (!repo || !rev || !fallback) { return; }

    function show(state, text, linkText, href) {
      el.setAttribute("data-state", state);
      el.textContent = text;
      if (linkText && href) {
        var link = document.createElement("a");
        link.href = href;
        link.textContent = linkText;
        link.rel = "noreferrer";
        el.appendChild(document.createTextNode(" "));
        el.appendChild(link);
      }
    }

    var repoPath = repo.split("/").map(encodeURIComponent).join("/");
    var api = "https://api.github.com/repos/" + repoPath +
              "/compare/" + encodeURIComponent(rev) + "...HEAD";
    show("checking", "Checking GitHub for agent-box updates…");
    fetch(api, {
      credentials: "omit",
      headers: { "Accept": "application/vnd.github+json" },
      referrerPolicy: "no-referrer"
    })
      .then(function (r) {
        if (!r.ok) { throw new Error("GitHub returned " + r.status); }
        return r.json();
      })
      .then(function (result) {
        if (result.status === "identical") {
          show("current", "No agent-box code update.");
          return;
        }
        if (result.status === "ahead") {
          var count = Number(result.ahead_by) || 0;
          var commits = count ? count + " commit" + (count === 1 ? "" : "s") : "new commits";
          var head = result.head_commit && result.head_commit.sha;
          var href = head
            ? "https://github.com/" + repoPath + "/compare/" +
              encodeURIComponent(rev) + "..." + encodeURIComponent(head)
            : fallback;
          show("available", "agent-box update available — " + commits + ".", "View changes", href);
          return;
        }
        show("blocked", "Automatic agent-box update unavailable.", "Compare revisions", fallback);
      })
      .catch(function () {
        show("unknown", "Couldn’t check agent-box updates.", "Check GitHub", fallback);
      });
  }

  var pollLeft = 0;
  var pollTimer = null;
  function schedulePoll() {
    if (pollTimer || pollLeft <= 0) { return; }
    if (!document.querySelector(
          "#sessions-list [data-state=starting], #tab-bar [data-state=starting]")) { return; }
    pollLeft -= 1;
    pollTimer = window.setTimeout(function () {
      pollTimer = null;
      // Keep the query string: on the workspace it carries ?tab=, so
      // the fetched tab bar marks the same tab current.
      fetch(window.location.pathname + window.location.search)
        .then(function (r) { return r.text(); })
        .then(function (t) {
          applyDoc(parseHTML(t), ["sessions-list", "tab-bar"]);
          wsSync();
          schedulePoll();
        });
    }, 2500);
  }
  function startPolling(n) { pollLeft = n; schedulePoll(); }

  // Tabbed terminal workspace (the HOME root page, issue #119). The
  // server renders tabs as plain ?tab= links and only the selected
  // pane; this upgrades clicks to client-side switching, creating
  // panes lazily on first activation and keeping them mounted after,
  // so background sessions stay attached like a terminal app's tabs.
  // Everything re-queries the DOM — polling replaces #tab-bar
  // wholesale, and a pane may be a placeholder until its session is
  // live (the ttyd attach wrapper errors out on a session that does
  // not exist yet).
  function tabBar() { return document.getElementById("tab-bar"); }
  function tabEl(name) {
    var bar = tabBar();
    return bar ? bar.querySelector('.tab[data-tab="' + name + '"]') : null;
  }
  function tabLive(name) {
    var t = tabEl(name);
    return !!(t && t.querySelector("[data-state=live]"));
  }
  function ensurePane(name) {
    var cur = document.querySelector('#panes .pane[data-pane="' + name + '"]');
    if (cur && (cur.tagName === "IFRAME" || !tabLive(name))) { return cur; }
    var el;
    if (tabLive(name)) {
      el = document.createElement("iframe");
      el.src = tabBar().getAttribute("data-term-base") +
               "?arg=" + encodeURIComponent(name);
      el.title = name + " terminal";
      el.setAttribute("allow", "clipboard-read; clipboard-write");
      el.className = "pane";
    } else {
      el = document.createElement("div");
      el.textContent = name + " is starting…";
      el.className = "pane placeholder";
    }
    el.setAttribute("data-pane", name);
    if (cur) {
      if (cur.classList.contains("active")) { el.classList.add("active"); }
      cur.replaceWith(el);
    } else {
      document.getElementById("panes").appendChild(el);
    }
    return el;
  }
  function wsSelect(name, focus) {
    var bar = tabBar();
    if (!bar || !tabEl(name)) { return; }
    bar.querySelectorAll(".tab").forEach(function (t) {
      if (t.getAttribute("data-tab") === name) { t.setAttribute("aria-current", "page"); }
      else { t.removeAttribute("aria-current"); }
    });
    var pane = ensurePane(name);
    document.querySelectorAll("#panes .pane").forEach(function (p) {
      p.classList.toggle("active", p === pane);
    });
    history.replaceState(null, "", "/?tab=" + encodeURIComponent(name));
    if (focus && pane.tagName === "IFRAME") {
      try { pane.contentWindow.focus(); } catch (err) { /* cross-origin never happens; be safe */ }
    }
  }
  function wsActive() {
    var bar = tabBar();
    var t = bar ? bar.querySelector(".tab[aria-current]") : null;
    return t ? t.getAttribute("data-tab") : null;
  }
  function wsSync() {
    if (!tabBar()) { return; }
    // Drop panes whose sessions are gone; upgrade placeholders whose
    // sessions came live. No focus steal — the user may be typing.
    document.querySelectorAll("#panes .pane[data-pane]").forEach(function (p) {
      var name = p.getAttribute("data-pane");
      if (!tabEl(name)) { p.remove(); return; }
      ensurePane(name);
    });
    var cur = wsActive();
    if (cur) { wsSelect(cur, false); }
  }
  document.addEventListener("click", function (e) {
    var t = e.target && e.target.closest ? e.target.closest("#tab-bar .tab[data-tab]") : null;
    if (!t) { return; }
    e.preventDefault();
    wsSelect(t.getAttribute("data-tab"), true);
  });

  // The editors render expanded (no-JS fallback); collapse them once
  // JS is live so the page opens in list-only, GitHub-style form.
  ["secret-editor", "session-editor", "password-editor"].forEach(function (id) {
    var el = document.getElementById(id);
    if (el) { el.hidden = true; }
  });

  document.addEventListener("click", function (e) {
    var t = e.target && e.target.closest ? e.target.closest("[data-toggle],[data-edit]") : null;
    if (!t) { return; }
    var form = document.getElementById("secret-form");
    if (t.hasAttribute("data-edit")) {
      document.getElementById("secret-editor").hidden = false;
      form.reset();
      var key = form.querySelector("input[name=key]");
      key.value = t.getAttribute("data-edit");
      key.readOnly = true;
      form.querySelector("input[name=value]").focus();
      return;
    }
    var el = document.getElementById(t.getAttribute("data-toggle"));
    if (!el) { return; }
    el.hidden = !el.hidden;
    if (!el.hidden && el.id === "secret-editor") {
      form.reset();
      var ki = form.querySelector("input[name=key]");
      ki.readOnly = false;
      ki.focus();
    }
  });

  document.addEventListener("submit", function (e) {
    var f = e.target;
    if (e.defaultPrevented || !f || (f.method || "").toLowerCase() !== "post") { return; }
    // Password rotation invalidates the current cookie and cached basic
    // credentials. Let the browser follow its native 303/401 flow so it
    // can prompt for the new password; fetch() suppresses that UX.
    if (f.hasAttribute("data-native")) { return; }
    e.preventDefault();
    var body = new URLSearchParams();
    new FormData(f).forEach(function (v, k) { body.append(k, v); });
    // On the workspace, adding a session should focus its new tab —
    // and a FAILED add (the fetched error page defaults aria-current)
    // must not yank the user off the tab they were on.
    var addedSession =
      (f.getAttribute("action") || "").endsWith("/sessions/add") && tabBar()
        ? body.get("name") : null;
    var wasActive = wsActive();
    var poll = f.getAttribute("data-poll");
    var statusUrl = f.getAttribute("data-status");

    function afterPost(t) {
      applyDoc(parseHTML(t), ["msg-slot", "secrets-list", "sessions-list", "tab-bar"]);
      var ed = f.closest(".editor");
      if (ed) { f.reset(); ed.hidden = true; }
      if (addedSession && tabEl(addedSession)) { wsSelect(addedSession, true); }
      else if (wasActive && tabEl(wasActive)) { wsSelect(wasActive, false); }
      wsSync();
    }
    function post() {
      return fetch(f.getAttribute("action"), { method: "POST", body: body })
        .then(function (r) { return r.text(); });
    }

    // The two Danger-zone actions get a long-polled progress line;
    // everything else keeps the brief session-state poll.
    if (poll === "update" && statusUrl) {
      // Snapshot the run's start time + rev BEFORE triggering, so the
      // watcher can distinguish the new run from any earlier one.
      fetchStatus(statusUrl).then(function (s0) {
        var baseline = (s0 && s0.update && typeof s0.update.since === "number")
          ? s0.update.since : 0;
        var rev0 = s0 ? s0.rev : null;
        post().then(function (t) { afterPost(t); watchUpdate(statusUrl, baseline, rev0); });
      });
      return;
    }
    if (poll === "restart" && statusUrl) {
      post().then(function (t) { afterPost(t); watchRestart(statusUrl); });
      return;
    }
    post().then(function (t) { afterPost(t); startPolling(8); });
  });

  // Working-directory autocomplete (issue #131). The add-session cwd
  // field browses the filesystem one level at a time: the daemon lists
  // the children of whatever directory the text names so far (up to
  // the last "/"), and the client filters those by the trailing
  // fragment. Picking an entry appends "<name>/" and re-fetches, so
  // the next level appears — like tab-completing a path. Everything is
  // event-delegated so it survives the DOM swaps applyDoc() does; each
  // input carries its own tiny state on the element.
  function acList(input) {
    var combo = input.closest ? input.closest(".combo") : null;
    return combo ? combo.querySelector(".ac") : null;
  }
  function acSplit(v) {
    // Directory portion (browsed) and trailing fragment (filter).
    var slash = v.lastIndexOf("/");
    if (slash < 0) { return { dir: "~", frag: v === "~" ? "" : v }; }
    return { dir: v.slice(0, slash) || "/", frag: v.slice(slash + 1) };
  }
  function acJoin(dir, name) {
    return (dir === "/" ? "/" : dir + "/") + name;
  }
  function acClose(input) {
    var ul = acList(input);
    if (ul) { ul.hidden = true; ul.innerHTML = ""; }
    var st = input._dir;
    if (st) { st.active = -1; }
  }
  function acRender(input) {
    var ul = acList(input);
    var st = input._dir;
    if (!ul || !st) { return; }
    var frag = acSplit(input.value).frag.toLowerCase();
    var matches = st.entries.filter(function (n) {
      return n.toLowerCase().indexOf(frag) === 0;
    });
    ul.innerHTML = "";
    st.active = -1;
    if (!st.entries.length) {
      var e = document.createElement("li");
      e.className = "empty";
      e.textContent = "No subfolders here";
      ul.appendChild(e);
      ul.hidden = false;
      return;
    }
    if (!matches.length) { ul.hidden = true; return; }
    matches.slice(0, 200).forEach(function (name) {
      var li = document.createElement("li");
      li.setAttribute("role", "option");
      li.setAttribute("data-name", name);
      li.textContent = name + "/";
      ul.appendChild(li);
    });
    ul.hidden = false;
  }
  function acFetch(input) {
    var st = input._dir || (input._dir = { dir: null, entries: [], active: -1, seq: 0 });
    var dir = acSplit(input.value).dir;
    if (dir === st.dir) { acRender(input); return; }
    var base = input.getAttribute("data-dir-base") || "";
    var my = ++st.seq;
    fetch(base + "/sessions/dirs?path=" + encodeURIComponent(dir), {
      headers: { "Accept": "application/json" }
    })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (my !== st.seq) { return; } // a newer keystroke won
        st.dir = dir;
        st.entries = (res && res.dirs) || [];
        acRender(input);
      })
      .catch(function () { acClose(input); });
  }
  function acItems(input) {
    var ul = acList(input);
    return ul ? [].slice.call(ul.querySelectorAll("li[data-name]")) : [];
  }
  function acHighlight(input, idx) {
    var items = acItems(input);
    var st = input._dir;
    if (!items.length || !st) { return; }
    if (idx < 0) { idx = items.length - 1; }
    if (idx >= items.length) { idx = 0; }
    items.forEach(function (li, i) {
      if (i === idx) { li.setAttribute("aria-selected", "true"); li.scrollIntoView({ block: "nearest" }); }
      else { li.removeAttribute("aria-selected"); }
    });
    st.active = idx;
  }
  function acApply(input, li) {
    var dir = acSplit(input.value).dir;
    input.value = acJoin(dir, li.getAttribute("data-name")) + "/";
    input.focus();
    acFetch(input); // reveal the next level
  }
  var acTimer = null;
  document.addEventListener("input", function (e) {
    var input = e.target;
    if (!input || !input.hasAttribute || !input.hasAttribute("data-dir-input")) { return; }
    if (acTimer) { window.clearTimeout(acTimer); }
    acTimer = window.setTimeout(function () { acTimer = null; acFetch(input); }, 120);
  });
  document.addEventListener("focusin", function (e) {
    var input = e.target;
    if (input && input.hasAttribute && input.hasAttribute("data-dir-input")) { acFetch(input); }
  });
  document.addEventListener("focusout", function (e) {
    var input = e.target;
    if (!input || !input.hasAttribute || !input.hasAttribute("data-dir-input")) { return; }
    // Delay so a mousedown-selected item still registers its click.
    window.setTimeout(function () { acClose(input); }, 150);
  });
  document.addEventListener("keydown", function (e) {
    var input = e.target;
    if (!input || !input.hasAttribute || !input.hasAttribute("data-dir-input")) { return; }
    var ul = acList(input);
    var open = ul && !ul.hidden;
    var st = input._dir;
    if (e.key === "ArrowDown") { e.preventDefault(); if (open) { acHighlight(input, (st ? st.active : -1) + 1); } else { acFetch(input); } }
    else if (e.key === "ArrowUp") { if (open) { e.preventDefault(); acHighlight(input, (st ? st.active : 0) - 1); } }
    else if (e.key === "Enter") {
      var items = acItems(input);
      if (open && st && st.active >= 0 && items[st.active]) {
        e.preventDefault(); // accept the suggestion, don't submit yet
        acApply(input, items[st.active]);
      }
    } else if (e.key === "Escape") { if (open) { e.preventDefault(); acClose(input); } }
  });
  document.addEventListener("mousedown", function (e) {
    var li = e.target && e.target.closest ? e.target.closest(".ac li[data-name]") : null;
    if (!li) { return; }
    e.preventDefault(); // keep focus on the input (no focusout close)
    var combo = li.closest(".combo");
    var input = combo ? combo.querySelector("[data-dir-input]") : null;
    if (input) { acApply(input, li); }
  });

  checkForUpdate();
  // Land in the terminal: focus the server-selected tab's pane.
  if (wsActive()) { wsSelect(wsActive(), true); }
  startPolling(8);
})();
