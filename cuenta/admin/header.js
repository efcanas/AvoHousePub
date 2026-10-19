/* Encabezado único compartido por AHtv, CC, Comunicaciones, Inventario y Estadísticas. */
(function () {
  "use strict";

  const mount = document.getElementById("adminHeaderMount");
  if (!mount) return;

  const activeSection = mount.dataset.section || "";
  const sections = [
    { id: "ahtv", label: "AHtv", title: "AHtv", href: "../../ahtv/admin/?v=20261019-1" },
    { id: "cc", label: "CC", title: "Centro de Control", href: "../../cuenta/admin/?v=20261019-1" },
    { id: "communications", label: "COMUNICACIONES", title: "Comunicaciones", href: "../../cuenta/comunicaciones/?v=20261019-1" },
    { id: "inventory", label: "INVENTARIO", title: "Inventario", href: "../../cuenta/inventario/?v=20261019-1" },
    { id: "statistics", label: "ESTADÍSTICAS", title: "Estadísticas", href: "../../cuenta/estadisticas/?v=20261019-1" }
  ];

  const current = sections.find(function (item) {
    return item.id === activeSection;
  }) || sections[0];

  const links = sections.map(function (item) {
    const active = item.id === activeSection;
    return '<a class="home-button' + (active ? ' active' : '') + '" href="' +
      item.href + '"' + (active ? ' aria-current="page"' : '') + '>' +
      item.label + '</a>';
  }).join("\n      ");

  mount.innerHTML =
    '<header class="header">' +
      '<img src="../../LogoPrincipal.png" class="logo" alt="AvoHouse Pub">' +
      '<div class="header-title">' + current.title + '</div>' +
      '<nav class="header-actions" aria-label="Navegación administrativa">' +
        links +
        '<button id="logoutBtn" class="hidden" type="button">CERRAR SESIÓN</button>' +
      '</nav>' +
    '</header>';

  /*
   * Las cuatro áreas administrativas distintas de AHtv reciben una separación
   * calculada desde el borde inferior real del encabezado, no una altura fija.
   * Así se mantiene el hueco en escritorio y cuando la navegación ocupa varias
   * filas en pantallas móviles.
   */
  function syncContentOffset() {
    if (activeSection === "ahtv") return;

    const page = mount.closest(".page");
    const header = mount.querySelector(".header");
    if (!page || !header) return;

    const gap = 12;
    const height = Math.ceil(header.getBoundingClientRect().height);
    page.style.paddingTop = (height + gap) + "px";
  }

  syncContentOffset();
  window.addEventListener("load", syncContentOffset);
  window.addEventListener("resize", syncContentOffset);

  if ("ResizeObserver" in window) {
    const headerObserver = new ResizeObserver(syncContentOffset);
    const header = mount.querySelector(".header");
    if (header) headerObserver.observe(header);
  }
})();
