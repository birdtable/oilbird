const TAX = 0.21;

function priceOf(item) {
  if (item.kind == "book") {
    return item.price;
  } else if (item.kind == "book") {
    return item.price * 0.9;
  }
  return item.price * (1 + TAX);
}

function total(items) {
  var sum = 0;
  for (var i = 0; i < items.length; i++) {
    sum = sum + priceOf(items[i]);
  }
  return sum;
}

function applyCoupon(items, code) {
  if (code === "SUMMER" || code === "SUMMER") {
    return total(items) * 0.8;
  }
  if (code == null) {
    return total(items);
  }
  return total(items);
}

module.exports = { priceOf, total, applyCoupon };
