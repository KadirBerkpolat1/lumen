// LM-FRAGMENT Stack Health tab (renderHealth) — MoonTools live diagnostics
// LM-FRAGMENT source fragment of lumen_menu, assembled in order into ONE IIFE
// LM-FRAGMENT by boot.lua (read_menu_js). Not a standalone module. See 01-core.js.

  var HEALTH_SVG = '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'
    + '<path fill="currentColor" d="M8 1.2 2.2 3.6v4.3c0 3.4 2.4 6.2 5.8 6.9 3.4-.7 5.8-3.5 5.8-6.9V3.6L8 1.2zm2.9 5.5L7.4 10.2a.75.75 0 0 1-1.06 0L4.9 8.76a.75.75 0 1 1 1.06-1.06l.91.91 2.97-2.97a.75.75 0 0 1 1.06 1.06z"/>'
    + '</svg>';

  function healthStringsSafe() {
    if (typeof healthStrings === "function") return healthStrings();
    var L = I18N[pickLang()] || I18N.en;
    return (L && L.health) || (I18N.en && I18N.en.health) || {
      tab: "Stack Health",
      title: "Stack Health",
      intro: "Live diagnostics for Steam 64-bit, slsteam-moon, CloudRedirect, and local tools.",
      refresh: "Refresh",
      loading: "Checking MoonTools stack\u2026",
      loadFail: "Could not read stack health: ",
      statusOk: "All systems healthy",
      statusWarn: "Attention recommended",
      statusError: "Action required",
      badgeOk: "OK",
      badgeWarn: "Warning",
      badgeError: "Error",
      archLabel: "Client architecture",
      profileLabel: "Active SLSsteam profile",
      fixesLabel: "Tracked fixes",
      checks: {
        steam: "Steam client",
        slssteam: "slsteam-moon injection",
        profile: "Config profile sync",
        cloudredirect: "CloudRedirect",
        filepicker: "Native file picker",
        fixes: "Fix backups",
      },
    };
  }

  function renderHealth(body) {
    var S = healthStringsSafe();
    body.textContent = "";
    var loading = document.createElement("div");
    loading.className = "lumen-note";
    loading.textContent = S.loading;
    body.appendChild(loading);

    return call("LumenStackHealth", {})
      .then(function (raw) {
        var data = typeof raw === "string" ? JSON.parse(raw) : raw;
        if (!data || !data.success) throw new Error((data && data.error) || "health check failed");
        body.textContent = "";

        var intro = document.createElement("div");
        intro.className = "lumen-note";
        intro.textContent = S.intro;
        body.appendChild(intro);

        var overall = data.status || "ok";
        var summary = document.createElement("div");
        summary.className = "lumen-health-summary is-" + overall;

        var sumLeft = document.createElement("div");
        sumLeft.className = "lumen-health-summary-copy";
        var sumTitle = document.createElement("strong");
        sumTitle.textContent = overall === "error" ? S.statusError
          : overall === "warn" ? S.statusWarn : S.statusOk;
        var sumMeta = document.createElement("span");
        sumMeta.textContent = S.archLabel + ": " + (data.arch || "unknown")
          + " \u00b7 " + S.fixesLabel + ": " + (data.trackedFixes || 0);
        sumLeft.appendChild(sumTitle);
        sumLeft.appendChild(sumMeta);

        var refreshBtn = document.createElement("button");
        refreshBtn.type = "button";
        refreshBtn.className = "lumen-account-button";
        refreshBtn.textContent = S.refresh;
        refreshBtn.addEventListener("click", function () { renderHealth(body); });

        summary.appendChild(sumLeft);
        summary.appendChild(refreshBtn);
        body.appendChild(summary);

        var grid = document.createElement("div");
        grid.className = "lumen-health-grid";
        var checkNames = S.checks || {};
        (data.checks || []).forEach(function (item) {
          var card = document.createElement("div");
          card.className = "lumen-health-card";
          var top = document.createElement("div");
          top.className = "lumen-health-card-top";
          var name = document.createElement("strong");
          name.textContent = checkNames[item.id] || item.id;
          var badge = document.createElement("span");
          var st = item.status || "ok";
          badge.className = "lumen-health-badge is-" + st;
          badge.textContent = st === "error" ? S.badgeError : st === "warn" ? S.badgeWarn : S.badgeOk;
          top.appendChild(name);
          top.appendChild(badge);
          card.appendChild(top);

          var detail = document.createElement("div");
          detail.className = "lumen-desc";
          detail.textContent = item.detail || "";
          card.appendChild(detail);

          if (item.path) {
            var p = document.createElement("div");
            p.className = "lumen-health-path";
            p.textContent = item.path;
            p.title = item.path;
            card.appendChild(p);
          }
          grid.appendChild(card);
        });
        body.appendChild(grid);
        return data;
      })
      .catch(function (e) {
        body.textContent = "";
        var err = document.createElement("div");
        err.className = "lumen-err";
        err.textContent = S.loadFail + (e && e.message ? e.message : e);
        body.appendChild(err);
      });
  }
