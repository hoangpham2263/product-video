// Runs in grok.com's own world (manifest "world": "MAIN"), beside sites/grok.js. Grok adds a video's last frame through
// a file chooser it opens from a hidden input (Add last frame); a page script cannot fill a chooser, so sites/grok.js
// first hands the file here (window message "arm-file") and the next file input the page opens gets it instead of the
// chooser. Only one file, once; then the page's own click works again.
(() => {
  let armed = null;
  const click = HTMLInputElement.prototype.click;
  const showPicker = HTMLInputElement.prototype.showPicker;
  const fill = (input) => {
    const { name, type, data } = armed;
    armed = null;
    const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
    const transfer = new DataTransfer();
    transfer.items.add(new File([bytes], name, { type }));
    input.files = transfer.files;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
    window.postMessage({ toolsHub: "file-used" }, location.origin);
  };
  HTMLInputElement.prototype.click = function () {
    if (armed && this.type === "file") return fill(this);
    return click.call(this);
  };
  if (showPicker) {
    HTMLInputElement.prototype.showPicker = function () {
      if (armed && this.type === "file") return fill(this);
      return showPicker.call(this);
    };
  }
  // From the content script's world: its messages need not come from this world's window object, so only the key counts.
  window.addEventListener("message", (event) => {
    if (event.origin !== location.origin || event.data?.toolsHub !== "arm-file") return;
    armed = event.data.file;
    window.postMessage({ toolsHub: "armed" }, location.origin);
  });
  window.postMessage({ toolsHub: "main-ready" }, location.origin);
})();
