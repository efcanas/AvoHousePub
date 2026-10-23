/* Catálogo público del menú AHP. Los precios, las imágenes y la visibilidad provienen de Supabase. */
(function () {
  "use strict";

  const SUPABASE_URL = "https://tjarildqqxtjmafpiyuz.supabase.co";
  const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_Clp6KIiLE-gKHGu3Lp8E2A_DxYhFBdT";
  const IMAGE_BUCKET = "menu-images";
  const SECTION_ROUTES = {
    mezcladitas: "mezcladitas.html",
    cervezas: "cervezas.html",
    sinalcohol: "sinalcohol.html",
    firma: "firma.html"
  };
  const body = document.body;
  const currentSectionId = body?.dataset?.menuSection || "";
  const container = document.getElementById("menuContent") || document.querySelector(".container");
  let client = null;

  function createClient() {
    if (!window.supabase?.createClient) return null;
    return window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false
      }
    });
  }

  function getImageUrl(imagePath) {
    const path = String(imagePath || "");
    if (path.startsWith("legacy:")) {
      return new URL(path.slice(7), window.location.href).href;
    }
    if (!client || !path) return "";
    return client.storage.from(IMAGE_BUCKET).getPublicUrl(path).data.publicUrl;
  }

  function formatPrice(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return "";
    return "$" + new Intl.NumberFormat("es-CO", {
      maximumFractionDigits: 0
    }).format(number);
  }

  function safeRoute(section) {
    return SECTION_ROUTES[section.id] === section.route ? section.route : null;
  }

  function replacePublicHeaderNavigation(sections) {
    document.querySelectorAll(".header-actions").forEach(function (nav) {
      const fragment = document.createDocumentFragment();
      const home = document.createElement("a");
      home.href = "index.html";
      home.className = "home-button";
      home.textContent = "Inicio";
      fragment.appendChild(home);

      sections.forEach(function (section) {
        const route = safeRoute(section);
        if (!route) return;
        const link = document.createElement("a");
        link.href = route;
        link.className = "home-button" + (section.id === currentSectionId ? " active" : "");
        link.textContent = section.title;
        if (section.id === currentSectionId) link.setAttribute("aria-current", "page");
        fragment.appendChild(link);
      });

      nav.replaceChildren(fragment);
    });
  }

  function replaceHomeMenuLinks(sections) {
    const menuButtons = document.querySelector(".menu-buttons");
    if (!menuButtons) return;

    Object.values(SECTION_ROUTES).forEach(function (route) {
      menuButtons.querySelectorAll("a[href]").forEach(function (link) {
        const href = link.getAttribute("href") || "";
        if (href.split("?")[0].split("#")[0] === route) link.remove();
      });
    });

    sections.forEach(function (section) {
      const route = safeRoute(section);
      if (!route) return;
      const link = document.createElement("a");
      link.href = route;
      link.textContent = section.title;
      menuButtons.appendChild(link);
    });
  }

  function createProductCard(item, section, index) {
    const card = document.createElement("div");
    card.className = "product-card";

    const image = document.createElement("img");
    image.src = getImageUrl(item.image_path);
    image.alt = item.name || section.title;
    image.className = item.image_class || "";
    image.loading = "eager";
    image.decoding = "async";
    image.tabIndex = 0;
    image.setAttribute("role", "button");
    image.setAttribute("aria-label", "Ampliar imagen: " + (item.name || section.title));
    if (index === 0) image.fetchPriority = "high";
    card.appendChild(image);

    if (section.show_names && item.name) {
      const name = document.createElement("div");
      name.className = "product-name";
      name.textContent = item.name;
      card.appendChild(name);
    }

    if (section.price_mode === "editable" && item.price_amount != null) {
      const price = document.createElement("div");
      price.className = "price";
      price.textContent = formatPrice(item.price_amount);
      card.appendChild(price);
    }

    return card;
  }

  function renderItems(section, items) {
    if (!container) return;
    const root = document.createElement("div");
    root.id = "menuProductsRoot";

    const groups = [];
    const groupMap = new Map();
    items.forEach(function (item) {
      const key = item.display_group || "";
      if (!groupMap.has(key)) {
        const group = { label: key, items: [] };
        groupMap.set(key, group);
        groups.push(group);
      }
      groupMap.get(key).items.push(item);
    });

    let flatIndex = 0;
    groups.forEach(function (group) {
      if (group.label) {
        const title = document.createElement("div");
        title.className = "section-title " +
          (group.label === "NACIONALES" ? "nacionales" :
           group.label === "EXTRANJERAS" ? "extranjeras" : "");
        title.textContent = group.label;
        root.appendChild(title);
      }

      const grid = document.createElement("div");
      grid.className = "product-grid";
      group.items.forEach(function (item) {
        grid.appendChild(createProductCard(item, section, flatIndex));
        flatIndex += 1;
      });
      root.appendChild(grid);
    });

    container.replaceChildren(root);
    container.style.visibility = "visible";
    container.classList.remove("menu-unavailable");
    body.classList.remove("menu-data-pending");
  }

  function showMessage(message) {
    if (!container) return;
    const panel = document.createElement("div");
    panel.className = "menu-status";
    panel.setAttribute("role", "status");
    panel.textContent = message;
    container.replaceChildren(panel);
    container.style.visibility = "visible";
    body.classList.remove("menu-data-pending");
  }

  function createImageLightbox() {
    let modal = document.getElementById("productImageLightbox");
    if (modal) return modal;

    modal = document.createElement("div");
    modal.id = "productImageLightbox";
    modal.className = "image-lightbox";
    modal.hidden = true;
    modal.setAttribute("role", "dialog");
    modal.setAttribute("aria-modal", "true");
    modal.setAttribute("aria-label", "Imagen ampliada");

    const enlarged = document.createElement("img");
    enlarged.id = "productImageLightboxImage";
    enlarged.className = "image-lightbox-image";
    enlarged.alt = "";
    enlarged.tabIndex = 0;
    modal.appendChild(enlarged);
    document.body.appendChild(modal);

    let previousFocus = null;
    let previousOverflow = "";

    function openImage(image) {
      previousFocus = image;
      previousOverflow = document.body.style.overflow;
      const visualClasses = Array.from(image.classList).filter(function (name) {
        return name.startsWith("neon-");
      });
      enlarged.className = ["image-lightbox-image"].concat(visualClasses).join(" ");
      enlarged.src = image.currentSrc || image.src;
      enlarged.alt = image.alt || "";
      modal.hidden = false;
      document.body.style.overflow = "hidden";
      enlarged.focus({ preventScroll: true });
    }

    function closeImage() {
      modal.hidden = true;
      enlarged.removeAttribute("src");
      enlarged.alt = "";
      enlarged.className = "image-lightbox-image";
      document.body.style.overflow = previousOverflow;
      if (previousFocus && document.contains(previousFocus)) {
        previousFocus.focus({ preventScroll: true });
      }
    }

    enlarged.addEventListener("click", closeImage);
    modal.addEventListener("click", function (event) {
      if (event.target === modal) closeImage();
    });
    document.addEventListener("click", function (event) {
      const image = event.target?.closest?.(".product-card img");
      if (image) openImage(image);
    });
    document.addEventListener("keydown", function (event) {
      if (!modal.hidden && event.key === "Escape") {
        event.preventDefault();
        closeImage();
        return;
      }
      const image = event.target?.closest?.(".product-card img");
      if (image && (event.key === "Enter" || event.key === " " || event.key === "Spacebar")) {
        event.preventDefault();
        openImage(image);
      }
    });

    return modal;
  }

  async function initialize() {
    if (!window.supabase?.createClient) {
      if (currentSectionId === "firma") {
        document.querySelector(".spacer")?.style.setProperty("display", "none");
        showMessage("No fue posible comprobar la disponibilidad de esta sección. Intenta recargar la página.");
      } else {
        body.classList.remove("menu-data-pending");
      }
      return;
    }

    client = createClient();
    if (!client) {
      if (currentSectionId === "firma") {
        document.querySelector(".spacer")?.style.setProperty("display", "none");
        showMessage("No fue posible comprobar la disponibilidad de esta sección. Intenta recargar la página.");
      } else {
        body.classList.remove("menu-data-pending");
      }
      return;
    }

    if (currentSectionId) createImageLightbox();

    try {
      const { data: sections, error: sectionsError } = await client
        .from("menu_sections")
        .select("id,title,route,visible,sort_order,price_mode,show_names")
        .order("sort_order", { ascending: true });

      if (sectionsError) throw sectionsError;
      const visibleSections = (sections || []).filter(function (section) {
        return section.visible === true && !!safeRoute(section);
      });

      replacePublicHeaderNavigation(visibleSections);
      replaceHomeMenuLinks(visibleSections);

      if (!currentSectionId || !container) {
        body.classList.remove("menu-data-pending");
        return;
      }

      const section = visibleSections.find(function (item) {
        return item.id === currentSectionId;
      });

      if (!section) {
        document.querySelector(".spacer")?.style.setProperty("display", "none");
        showMessage("Esta sección del menú no está disponible en este momento.");
        return;
      }

      const { data: items, error: itemsError } = await client
        .from("menu_items")
        .select("id,section_id,name,image_path,price_amount,display_order,display_group,image_class,is_active")
        .eq("section_id", section.id)
        .eq("is_active", true)
        .order("display_order", { ascending: true });

      if (itemsError) throw itemsError;
      if (!items?.length) {
        showMessage("Esta sección no tiene productos disponibles en este momento.");
        return;
      }

      renderItems(section, items);
      createImageLightbox();
    } catch (error) {
      console.warn("[AHP Menú] Se conservó la presentación local porque no fue posible actualizar el catálogo.", error?.message || "");
      if (currentSectionId === "firma") {
        showMessage("No fue posible comprobar la disponibilidad de esta sección. Intenta recargar la página.");
        document.querySelector(".spacer")?.style.setProperty("display", "none");
      } else {
        body.classList.remove("menu-data-pending");
      }
    }
  }

  if (currentSectionId) body.classList.add("menu-data-pending");
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initialize, { once: true });
  } else {
    initialize();
  }
})();