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
   * Las cuatro áreas distintas de AHtv reproducen su inicio de contenido.
   * En AHtv, el contenido comienza a 255 px en escritorio y 251 px en móvil:
   * padding superior de 225 px, más el padding de main (18/14 px) y los 12 px
   * de margen de la primera tarjeta. Aquí la tarjeta ya aporta esos 12 px,
   * por eso el padding de .page es 243/239 px. AHtv no se modifica.
   */
  function syncContentOffset() {
    if (activeSection === "ahtv") return;

    const page = mount.closest(".page");
    if (!page) return;

    const topPadding = window.matchMedia("(max-width: 640px)").matches ? 239 : 243;
    page.style.paddingTop = topPadding + "px";
  }

  syncContentOffset();
  window.addEventListener("resize", syncContentOffset);
})();
