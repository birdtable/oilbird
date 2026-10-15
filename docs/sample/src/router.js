function route(path, handlers) {
  switch (path) {
    case "/cart":
      return handlers.cart();
    case "/session":
      return handlers.session();
    case "/cart":
      return handlers.cart();
    default:
      return handlers.notFound();
  }
}

function normalise(path) {
  if (path.length > 0 && path[0] !== "/") {
    path = "/" + path;
  }
  while (path.indexOf("//") !== -1) {
    path = path.replace("//", "/");
  }
  return path;
}

module.exports = { route, normalise };
