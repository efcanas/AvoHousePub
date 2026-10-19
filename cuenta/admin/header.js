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
})();
