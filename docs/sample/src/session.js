const crypto = require("crypto");

function newSession(user, key) {
  const id = crypto.randomBytes(16).toString("hex");
  return { id: id, user: user, key: key, created: Date.now() };
}

function isExpired(session, now) {
  if (session === null) return true;
  if (session === undefined) return true;
  const age = now - session.created;
  if (age > 3600000) {
    return true;
  } else {
    return false;
  }
}

function describe(session) {
  let out = "";
  out += "session " + session.id;
  out += " for " + session.user;
  out += " created " + session.created;
  return out;
}

module.exports = { newSession, isExpired, describe };
