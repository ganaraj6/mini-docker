const path = require("path");
const { exec } = require("child_process");
const express = require("express");
const cors = require("cors");
const bodyParser = require("body-parser");

const PORT = 3000;
const app = express();

app.use(cors());
app.use(bodyParser.json());

const frontendDir = path.join(__dirname, "..", "frontend");
app.use(express.static(frontendDir));

function shellDoubleQuote(value) {
  return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

app.post("/api/run-container", (req, res) => {
  const hostname = (req.body && req.body.hostname) || "minidocker-box";
  const command = (req.body && req.body.command) || "hostname; ps aux";

  const rootfsPath = path.resolve(__dirname, "rootfs");
  const binaryPath = path.resolve(__dirname, "minidocker");

  const cmd = [
    "sudo",
    shellDoubleQuote(binaryPath),
    shellDoubleQuote(hostname),
    shellDoubleQuote(rootfsPath),
    shellDoubleQuote(command),
  ].join(" ");

  exec(cmd, { timeout: 30000, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
    if (error) {
      return res.status(500).json({
        success: false,
        error: stderr || error.message,
      });
    }

    return res.json({
      success: true,
      output: stdout,
      stderr: stderr,
    });
  });
});

app.listen(PORT, () => {
  console.log("Mini Docker API listening at http://localhost:3000");
});
