/* Encabezado único compartido por AHtv, CC, Comunicaciones, Inventario, Estadísticas y Menú. */
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
    { id: "statistics", label: "ESTADÍSTICAS", title: "Estadísticas", href: "../../cuenta/estadisticas/?v=20261019-1" },
    { id: "menu", label: "MENÚ", title: "Menú", href: "../../cuenta/menu/?v=20261023-1" }
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
   * Conserva exactamente 12 px entre el borde inferior del encabezado fijo
   * y el primer bloque visible de cada apartado. Se mide el bloque real para
   * descontar sus márgenes CSS (por ejemplo, el margen superior de las tarjetas).
   */
  const contentContainer = mount.closest(".page") || mount.closest("main") || document.body;

  function getFirstVisibleContent() {
    const candidates = contentContainer.querySelectorAll(".card, .notice:not([hidden])");
    for (const element of candidates) {
      if (mount.contains(element)) continue;
      const style = window.getComputedStyle(element);
      if (style.display === "none" || style.visibility === "hidden" || element.hidden) continue;
      if (element.getClientRects().length) return element;
    }
    return null;
  }

  function syncContentOffset() {
    const header = mount.querySelector(".header");
    const content = getFirstVisibleContent();
    if (!header || !content) return;

    const desiredTop = header.getBoundingClientRect().bottom + window.scrollY + 12;
    const currentTop = content.getBoundingClientRect().top + window.scrollY;
    const delta = desiredTop - currentTop;

    if (Math.abs(delta) < 0.5) return;

    const currentPadding = parseFloat(window.getComputedStyle(contentContainer).paddingTop) || 0;
    contentContainer.style.paddingTop = (currentPadding + delta) + "px";
  }

  syncContentOffset();
  window.addEventListener("load", syncContentOffset);
  window.addEventListener("resize", syncContentOffset);

  if ("ResizeObserver" in window) {
    const headerObserver = new ResizeObserver(syncContentOffset);
    headerObserver.observe(mount.querySelector(".header"));
  }

  const contentObserver = new MutationObserver(syncContentOffset);
  contentObserver.observe(contentContainer, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["class", "hidden", "style"]
  });

  // Permite que los apartados con contenido que llega después de verificar la sesión
  // soliciten el mismo cálculo de espaciado del encabezado centralizado.
  window.ahAdminHeaderSyncContentOffset = syncContentOffset;
})();
