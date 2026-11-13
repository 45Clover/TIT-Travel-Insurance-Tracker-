(function () {
  const geoJsonUrl =
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson";
  const countries = [];
  let map;
  let countryLayer;
  let selectedKey = "";

  function countryKey(country) {
    return country.iso3 || country.iso2 || country.name;
  }

  function countryStyle(feature) {
    const key = countryKey(feature);
    return {
      color: key === selectedKey ? "#ffe36e" : "#d9d3bb",
      weight: key === selectedKey ? 2.5 : 0.8,
      opacity: key === selectedKey ? 1 : 0.8,
      fillColor: key === selectedKey ? "#ffe36e" : "#65745d",
      fillOpacity: key === selectedKey ? 0.4 : 0.12,
    };
  }

  function notifyShiny(country) {
    if (!country || !window.Shiny) return;
    window.Shiny.setInputValue(
      "selected_country",
      {
        name: country.name,
        code3: country.iso3,
        code2: country.iso2,
      },
      { priority: "event" }
    );
  }

  function selectCountry(country, layer) {
    if (!country) return;
    selectedKey = countryKey(country);
    const search = document.getElementById("country-search");
    if (search) search.value = country.name;
    if (countryLayer) countryLayer.setStyle(countryStyle);
    if (layer && layer.getBounds().isValid()) {
      map.fitBounds(layer.getBounds(), { padding: [24, 24], maxZoom: 5 });
    }
    notifyShiny(country);
  }

  function addCountryInteractions(feature, layer) {
    layer.bindTooltip(feature.name, { sticky: true, direction: "auto" });
    layer.on({
      mouseover: function () {
        if (countryKey(feature) !== selectedKey) {
          layer.setStyle({ color: "#fff2a8", weight: 1.7, fillColor: "#ffe36e", fillOpacity: 0.28 });
        }
      },
      mouseout: function () {
        countryLayer.resetStyle(layer);
      },
      click: function () {
        selectCountry(feature, layer);
      },
    });
  }

  function addSearchOptions() {
    const list = document.getElementById("country-options");
    if (!list) return;
    countries.forEach(function (country) {
      const option = document.createElement("option");
      option.value = country.name;
      option.label = [country.iso3, country.iso2].filter(Boolean).join(" · ");
      list.appendChild(option);
    });
  }

  function loadCountries() {
    fetch(geoJsonUrl)
      .then(function (response) {
        if (!response.ok) throw new Error("Could not load country boundaries.");
        return response.json();
      })
      .then(function (geojson) {
        geojson.features.forEach(function (feature) {
          const properties = feature.properties || {};
          feature.name =
            properties.name || properties.ADMIN || properties.NAME_EN || "Unknown";
          feature.iso3 =
            properties["ISO3166-1-Alpha-3"] ||
            properties.ISO_A3 ||
            properties.ADM0_A3 ||
            properties.ISO_A3_EH ||
            "";
          feature.iso2 =
            properties["ISO3166-1-Alpha-2"] ||
            properties.ISO_A2 ||
            properties.ISO_A2_EH ||
            "";
          countries.push(feature);
        });

        countryLayer = L.geoJSON(countries, {
          style: countryStyle,
          onEachFeature: addCountryInteractions,
        }).addTo(map);
        addSearchOptions();
        document.getElementById("map-loading").style.display = "none";
      })
      .catch(function (error) {
        document.getElementById("map-loading").style.display = "none";
        const message = document.getElementById("map-error");
        message.textContent = error.message + " Check your internet connection and reload.";
        message.style.display = "block";
      });
  }

  function initializeMap() {
    const container = document.getElementById("world-map");
    if (!container || !window.L) return;

    map = L.map(container, {
      worldCopyJump: true,
      minZoom: 2,
      maxZoom: 7,
      zoomControl: true,
    }).setView([22, 8], 2);

    L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", {
      attribution:
        "Imagery &copy; Esri and contributors",
      maxZoom: 7,
    }).addTo(map);

    const search = document.getElementById("country-search");
    search.addEventListener("change", function () {
      const query = search.value.trim().toLocaleLowerCase();
      const country = countries.find(function (item) {
        return (
          item.name.toLocaleLowerCase() === query ||
          item.iso2.toLocaleLowerCase() === query ||
          item.iso3.toLocaleLowerCase() === query
        );
      });
      if (!country || !countryLayer) return;
      let selectedLayer;
      countryLayer.eachLayer(function (layer) {
        if (layer.feature === country) selectedLayer = layer;
      });
      selectCountry(country, selectedLayer);
    });

    loadCountries();
    window.setTimeout(function () {
      map.invalidateSize();
    }, 250);
  }

  document.addEventListener("DOMContentLoaded", initializeMap);
})();
