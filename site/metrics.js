(function () {
  var format = {
    mib: function (v) {
      return (v / 1048576).toFixed(1) + " MiB";
    },
    "mib-from-kib": function (v) {
      return (v / 1024).toFixed(0) + " MiB";
    },
    duration: function (v) {
      if (v < 60) return v + " s";
      var m = v / 60;
      return (m % 1 === 0 ? m : m.toFixed(1)) + " min";
    },
    ms: function (v) {
      return v >= 1000 ? (v / 1000).toFixed(2) + " s" : Math.round(v) + " ms";
    },
    s: function (v) {
      return v >= 1000 ? (v / 1000).toFixed(2) + " s" : Math.round(v) + " ms";
    },
  };

  function paint(doc) {
    var values = doc.values || {};
    document.querySelectorAll("[data-metric]").forEach(function (el) {
      var raw = values[el.getAttribute("data-metric")];
      if (raw === undefined || raw === null) {
        el.textContent = "—";
        el.setAttribute("title", "not measured on this build");
        return;
      }
      var fn = format[el.getAttribute("data-unit")];
      el.textContent = fn ? fn(raw) : String(raw);
      el.removeAttribute("title");
    });

    var method = doc.method || {};
    var fields = {
      "[data-method-host]": method.host,
      "[data-method-os]": method.os,
      "[data-method-version]": method.version,
      "[data-method-statistic]": method.statistic,
      "[data-method-runs]": method.runs,
      "[data-method-date]": doc.measured_at,
    };
    Object.keys(fields).forEach(function (sel) {
      var el = document.querySelector(sel);
      if (el) el.textContent = fields[sel] === undefined ? "—" : String(fields[sel]);
    });
  }

  fetch("metrics.json", { cache: "no-cache" })
    .then(function (r) {
      if (!r.ok) throw new Error(r.status);
      return r.json();
    })
    .then(paint)
    .catch(function () {
      var note = document.querySelector("[data-method]");
      if (note) note.textContent = "No measurements have been published for this build yet.";
    });

  var shot = document.querySelector(".demo img");
  if (shot) {
    shot.addEventListener("error", function () {
      var fig = shot.closest("figure");
      if (!fig) return;
      var box = document.createElement("pre");
      box.className = "ms-term";
      box.textContent =
        "The recording has not been generated for this build.\n" +
        "Run  asciinema rec --command ./site/demo.sh site/demo.cast\n" +
        "then  agg site/demo.cast site/demo.gif";
      fig.replaceChild(box, shot);
    });
  }
})();
