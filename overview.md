# Fin o'Flaherty - Portfolio Website

This project is a Hugo-based portfolio website for **Fin o'Flaherty**, a Site Reliability Engineer III. It uses the **Hugo Minimal Black** theme, a minimal, dark-mode first design centered around developer experience, minimalism, and visual excellence.

## Site Structure 

- **`hugo.toml`**: Global configuration file containing website metadata, hero details, social profiles, navigation menus, and the technology marquee definitions.
- **`content/`**: Markdown files containing pages, projects, and posts:
  - `_index.md`: Represents the homepage (empty, pages are driven by layout sections).
  - `about/`: Standard profile page using a timeline layout.
  - `about-alternative/`: Alternative profile layout featuring a left sidebar card and configurable stats grid.
  - `projects/`: Showcases engineering projects (e.g., bare-metal Kubernetes, custom ESP32 hardware, AWS codification, etc.).
  - `blog/`: Technical SRE debugging and troubleshooting case studies.
- **`themes/minimal-black/`**: The active theme which controls the styling via CSS variables (base, utilities, components, content, and page layouts).

## Build & Deployment

- To compile the site: `hugo`
- To run a local development server: `hugo server`
