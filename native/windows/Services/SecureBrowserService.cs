using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace AssignmentNative.Services;

public sealed class SecureBrowserService
{
    private readonly WebView2 _webView;

    public SecureBrowserService(WebView2 webView)
    {
        _webView = webView;
    }

    public Uri? CurrentUri =>
        Uri.TryCreate(_webView.Source?.AbsoluteUri, UriKind.Absolute, out var uri)
            ? uri
            : null;

    public async Task InitializeAsync()
    {
        var userDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AssignmentNative",
            "WebView2");
        Directory.CreateDirectory(userDataFolder);
        var environment = await CoreWebView2Environment.CreateWithOptionsAsync(
            string.Empty,
            userDataFolder,
            new CoreWebView2EnvironmentOptions());
        await _webView.EnsureCoreWebView2Async(environment);
        _webView.CoreWebView2.Settings.AreDefaultScriptDialogsEnabled = true;
        _webView.CoreWebView2.Settings.AreDevToolsEnabled = false;
        _webView.CoreWebView2.Settings.IsPasswordAutosaveEnabled = false;
        _webView.CoreWebView2.Settings.IsGeneralAutofillEnabled = false;
        _webView.CoreWebView2.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
        };
        _webView.CoreWebView2.DownloadStarting += (_, args) =>
        {
            args.Cancel = true;
        };
    }

    public void Navigate(string address)
    {
        var prepared = address.Contains("://", StringComparison.Ordinal)
            ? address
            : $"https://{address}";
        if (!Uri.TryCreate(prepared, UriKind.Absolute, out var uri) ||
            uri.Scheme is not ("http" or "https") ||
            string.IsNullOrWhiteSpace(uri.Host))
        {
            throw new InvalidOperationException("Enter a valid HTTP or HTTPS address.");
        }
        _webView.Source = uri;
    }

    public async Task FillAsync(StoredCredential credential)
    {
        var current = CurrentUri
            ?? throw new InvalidOperationException("Open a login page first.");
        var origin = CredentialVaultService.ExactSecureOrigin(current);
        if (!origin.Equals(
                credential.Origin,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "The saved credential does not match the current page host.");
        }

        var username = JsonSerializer.Serialize(credential.Username);
        var password = JsonSerializer.Serialize(credential.Password);
        var script =
            $$"""
            (() => {
              const username = {{username}};
              const password = {{password}};
              const visible = element => {
                const style = window.getComputedStyle(element);
                const box = element.getBoundingClientRect();
                return !element.disabled && style.visibility !== 'hidden' &&
                  style.display !== 'none' && box.width > 0 && box.height > 0;
              };
              const passwordField =
                [...document.querySelectorAll('input[type="password"]')].find(visible);
              if (!passwordField) return { success: false };
              const selectors = [
                'input[autocomplete="username"]', 'input[type="email"]',
                'input[name*="user" i]', 'input[id*="user" i]',
                'input[name*="email" i]', 'input[id*="email" i]',
                'input[type="text"]'
              ];
              let usernameField = null;
              for (const selector of selectors) {
                usernameField = [...document.querySelectorAll(selector)].find(visible);
                if (usernameField) break;
              }
              const setValue = (field, value) => {
                if (!field) return;
                const setter = Object.getOwnPropertyDescriptor(
                  window.HTMLInputElement.prototype, 'value').set;
                setter.call(field, value);
                field.dispatchEvent(new Event('input', { bubbles: true }));
                field.dispatchEvent(new Event('change', { bubbles: true }));
              };
              setValue(usernameField, username);
              setValue(passwordField, password);
              passwordField.focus();
              return { success: true };
            })()
            """;
        var result = await _webView.ExecuteScriptAsync(script);
        using var document = JsonDocument.Parse(result);
        if (!document.RootElement.TryGetProperty("success", out var success) ||
            !success.GetBoolean())
        {
            throw new InvalidOperationException(
                "No visible password field was found on this page.");
        }
        // Intentionally never clicks a submit button.
    }

    public async Task<CapturedPage> CapturePageAsync()
    {
        if (CurrentUri is null)
        {
            throw new InvalidOperationException("Open a page before scanning.");
        }
        const string script =
            """
            (() => {
              const visible = element => {
                const style = window.getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                return style.display !== 'none' && style.visibility !== 'hidden' &&
                  Number(style.opacity || 1) > 0 && rect.width > 0 && rect.height > 0;
              };
              const excluded = new Set([
                'SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'CANVAS',
                'INPUT', 'TEXTAREA', 'SELECT', 'OPTION'
              ]);
              const chunks = [];
              let length = 0;
              const walker = document.createTreeWalker(
                document.body, NodeFilter.SHOW_TEXT);
              while (walker.nextNode()) {
                const node = walker.currentNode;
                const parent = node.parentElement;
                if (!parent || excluded.has(parent.tagName) || !visible(parent)) continue;
                const value = (node.textContent || '').replace(/\s+/g, ' ').trim();
                if (value) {
                  chunks.push(value);
                  length += value.length + 1;
                }
                if (length > 60000) break;
              }
              const links = [...document.querySelectorAll('a[href]')]
                .filter(visible)
                .map(link => ({
                  text: (link.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 240),
                  url: link.href
                }))
                .filter(link => {
                  try {
                    return link.text && new URL(link.url).origin === location.origin;
                  } catch (_) {
                    return false;
                  }
                })
                .slice(0, 250);
              return {
                url: location.href,
                title: document.title || '',
                text: chunks.join('\n').slice(0, 60000),
                links
              };
            })()
            """;
        var raw = await _webView.ExecuteScriptAsync(script);
        return JsonSerializer.Deserialize<CapturedPage>(
            raw,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException(
                "The visible page content could not be captured.");
    }
}
