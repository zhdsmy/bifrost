// Adapted from po0fw asus-merlin (MIT), commit 0d9532d.
// Only the ASUS shell globals used by Module_bifrost.asp.
function E(id) { return document.getElementById(id); }
var tabtitle = [[]];
var tablink = [[]];
function show_menu(hook) {
  hook();
  var english = new URLSearchParams(location.search).get("preview_shell_lang") === "en";
  document.getElementById("TopBanner").innerHTML = "<b>ASUS</b><span>ASUSWRT-Merlin</span>";
  document.getElementById("mainMenu").textContent = english ? "Network Tools" : "网络工具";
  document.getElementById("subMenu").textContent = english ? "Software Center" : "软件中心";
  document.getElementById("tabMenu").textContent = tabtitle.at(-1)[1];
  document.getElementById("footer").textContent = "ASUSWRT-Merlin";
  // The firmware's state.js wraps everything beside #tabMenu in a new div after
  // load. The move reconnects #bifrost-app, which reloads its stylesheet.
  var cell = document.getElementById("tabMenu").parentNode;
  var wrapper = document.createElement("div");
  wrapper.className = "preview-moved";
  wrapper.append(...cell.children);
  cell.append(wrapper);
}
function reload_Soft_Center() {
  location.href = "/Module_Softcenter.asp";
}
