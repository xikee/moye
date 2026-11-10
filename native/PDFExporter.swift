import AppKit
import WebKit

// PDF 使用独立的静态排版视图，避免应用的滚动容器影响分页。
final class PDFExporter: NSObject, WKNavigationDelegate {
    private var view: WKWebView!
    private var continuation: CheckedContinuation<Void, Error>?
    private let resources: ResourceHandler

    init(resources: ResourceHandler) { self.resources = resources }

    @MainActor func render(html: String, to destination: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(resources, forURLScheme: "moye")
        let width: CGFloat = 499.28
        let pageHeight: CGFloat = 753.89
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800), configuration: configuration)
        view.navigationDelegate = self
        let style = "<style>body{width:auto;max-width:none;margin:0;padding:0;font-size:11px;line-height:1.9}h1{font-size:23px}h2{font-size:16px}h3{font-size:13px}pre{white-space:pre-wrap;overflow-wrap:anywhere}img{max-height:680px;object-fit:contain}*{box-sizing:border-box}</style>"
        let document = html.replacingOccurrences(of: "</head>", with: style + "</head>")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            view.loadHTMLString(document, baseURL: URL(string: "moye://document/"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self = self, let continuation = self.continuation else { return }
                self.continuation = nil
                self.view.stopLoading()
                continuation.resume(throwing: NSError(domain: "MoYe.PDF", code: 4, userInfo: [NSLocalizedDescriptionKey: "图片或文档载入超时，请检查网络后重试。 "]))
            }
        }
        let metricsScript = """
        (() => {
          const height = Math.max(1, Math.ceil(document.body.getBoundingClientRect().bottom + 10));
          const blocks = [...document.querySelectorAll('p,h1,h2,h3,h4,pre,blockquote,tr,img')].map(el => {
            const rect = el.getBoundingClientRect(); return {top:rect.top,bottom:rect.bottom,height:rect.height};
          });
          const lines = [];
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (!node.textContent.trim()) continue;
            const range = document.createRange(); range.selectNodeContents(node);
            for (const rect of range.getClientRects()) if (rect.height) lines.push({top:rect.top,bottom:rect.bottom});
          }
          const cuts = [0];
          while (cuts[cuts.length-1] + \(pageHeight) < height) {
            const start = cuts[cuts.length-1];
            let end = start + \(pageHeight);
            const block = blocks.find(b => b.top < end && b.bottom > end && b.height < \(pageHeight * 0.65) && b.top > start + \(pageHeight * 0.55));
            if (block) end = block.top - 3;
            for (let attempt=0; attempt<10; attempt++) {
              const crossing = lines.filter(line => line.top < end && line.bottom > end);
              if (!crossing.length) break;
              end = Math.min(...crossing.map(line => line.top)) - 1;
            }
            cuts.push(Math.max(start + 20, end));
            if (cuts.length > 500) throw new Error('文档超过 500 页');
          }
          cuts.push(height);
          return {height,cuts};
        })()
        """
        guard let metrics = try await view.evaluateJavaScript(metricsScript) as? [String: Any],
              let height = metrics["height"] as? Double,
              let cuts = metrics["cuts"] as? [Double], height > 0, height < 400_000 else {
            throw NSError(domain: "MoYe.PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "文档排版尺寸无效。"])
        }
        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        let data = try await view.pdf(configuration: pdfConfiguration)
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), let sourcePage = pdf.page(at: 1) else {
            throw NSError(domain: "MoYe.PDF", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法生成 PDF 页面。"])
        }
        let output = NSMutableData()
        var paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &paper, nil) else {
            throw NSError(domain: "MoYe.PDF", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法创建 PDF 文件。"])
        }
        for index in 0..<(cuts.count - 1) {
            context.beginPDFPage(nil)
            context.saveGState()
            let sliceHeight = min(pageHeight, cuts[index + 1] - cuts[index])
            context.clip(to: CGRect(x: 48, y: paper.height - 44 - sliceHeight, width: width, height: sliceHeight))
            context.translateBy(x: 48, y: paper.height - 44 - height + cuts[index])
            context.drawPDFPage(sourcePage)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        try (output as Data).write(to: destination, options: .atomic)
        view.navigationDelegate = nil
        view = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
