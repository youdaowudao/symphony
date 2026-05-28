defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Multi-Project Operations Home</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          function parsePositiveInt(value) {
            var parsed = parseInt(value || "0", 10);
            return Number.isFinite(parsed) ? Math.max(parsed, 0) : 0;
          }

          function formatRuntimeSeconds(totalSeconds) {
            var seconds = parsePositiveInt(totalSeconds);
            var mins = Math.floor(seconds / 60);
            var secs = seconds % 60;
            return mins + "m " + secs + "s";
          }

          function formatRuntimeAndTurns(totalSeconds, turnCount) {
            var seconds = parsePositiveInt(totalSeconds);
            var mins = Math.floor(seconds / 60);
            return mins + "m · t" + parsePositiveInt(turnCount);
          }

          function formatPollCountdown(nextPollInSeconds) {
            var remaining = Math.max(parsePositiveInt(nextPollInSeconds), 0);
            return "轮询 " + remaining + "s";
          }

          function formatPollChecking() {
            return "checking now…";
          }

          function formatPollUnknown() {
            return "轮询时间未知";
          }

          var Hooks = {};

          Hooks.LiveTicker = {
            mounted: function () {
              this.renderTicker();
              this.startTicker();
            },

            updated: function () {
              this.renderTicker();
              this.startTicker();
            },

            destroyed: function () {
              this.stopTicker();
            },

            disconnected: function () {
              this.stopTicker();
            },

            reconnected: function () {
              this.renderTicker();
              this.startTicker();
            },

            startTicker: function () {
              this.stopTicker();

              if (!this.shouldTick()) {
                return;
              }

              var self = this;
              this._tickerTimer = window.setInterval(function () {
                self.renderTicker();
              }, 1000);
            },

            stopTicker: function () {
              if (this._tickerTimer) {
                window.clearInterval(this._tickerTimer);
                this._tickerTimer = null;
              }
            },

            shouldTick: function () {
              var kind = this.el.dataset.liveDuration || this.el.dataset.ticker;
              if (kind === "runtime-total" || kind === "running-entry") {
                return true;
              }

              if (kind === "poll-countdown") {
                return this.el.dataset.pollState === "countdown";
              }

              return false;
            },

            ownerNode: function () {
              return this.el.querySelector("[data-ticker-owner]");
            },

            renderTicker: function () {
              var kind = this.el.dataset.liveDuration || this.el.dataset.ticker;
              var nowUnix = Math.floor(Date.now() / 1000);
              var owner = this.ownerNode();

              if (!owner) {
                return;
              }

              if (kind === "runtime-total") {
                var runtimeBaseSeconds = parsePositiveInt(this.el.dataset.baseSeconds);
                var runtimeAnchorUnix = parsePositiveInt(this.el.dataset.anchorUnix);
                var runtimeGrowth = parsePositiveInt(this.el.dataset.growthPerSecond);
                var runtimeElapsed = Math.max(nowUnix - runtimeAnchorUnix, 0);
                owner.textContent = formatRuntimeSeconds(runtimeBaseSeconds + runtimeElapsed * runtimeGrowth);
                return;
              }

              if (kind === "running-entry") {
                var entryBaseSeconds = parsePositiveInt(this.el.dataset.baseSeconds);
                var entryAnchorUnix = parsePositiveInt(this.el.dataset.anchorUnix);
                var entryTurnCount = parsePositiveInt(this.el.dataset.turnCount);
                var entryElapsed = Math.max(nowUnix - entryAnchorUnix, 0);
                owner.textContent = formatRuntimeAndTurns(entryBaseSeconds + entryElapsed, entryTurnCount);
                return;
              }

              if (kind === "poll-countdown") {
                var pollState = this.el.dataset.pollState;

                if (pollState === "checking") {
                  owner.textContent = formatPollChecking();
                  return;
                }

                if (pollState !== "countdown") {
                  owner.textContent = formatPollUnknown();
                  return;
                }

                var nextPollInSeconds = parsePositiveInt(this.el.dataset.nextPollInSeconds);
                owner.textContent = formatPollCountdown(nextPollInSeconds);
                this.el.dataset.nextPollInSeconds = String(Math.max(nextPollInSeconds - 1, 0));
              }
            }
          };

          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: Hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
