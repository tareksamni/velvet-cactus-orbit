// Minimal progressive enhancement. No framework, no build step — this file is
// copied verbatim into the shared emptyDir volume and served by nginx.

(function () {
  "use strict";

  var form = document.getElementById("upload-form");
  if (!form) return;

  form.addEventListener("submit", function () {
    var button = form.querySelector("button");
    var spinner = form.querySelector(".spinner");
    if (button) {
      button.disabled = true;
      button.textContent = "Processing…";
    }
    if (spinner) spinner.hidden = false;
  });
})();
