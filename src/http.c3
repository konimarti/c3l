<*
 HTTP(S) and file:// over libcurl. Redirects are followed (GitHub release
 downloads redirect). A failed transfer is not a fault: `Response.error` says why,
 and the caller words the message, it knows what was being fetched.
*>
module c3l::http;

import std::io, std::os, curl, c3l::sys;

const usz MAX_BODY = 64 * 1024 * 1024;
const long SSLOPT_REVOKE_BEST_EFFORT @private = 1 << 3;  // CURLSSLOPT_REVOKE_BEST_EFFORT

struct Response
{
	int status;          // HTTP status; 0 for file:// or when the transfer failed
	String body;         // empty when downloaded to a file
	String error;        // why the transfer failed, empty otherwise
	String retry_after;  // the Retry-After header, if any
}

// The transfer worked and the server did not answer with an error status.
fn bool Response.ok(&self) => !self.error.len && self.status < 400;

// Why it did not work, for messages.
fn String Response.why(&self) => self.error.len ? self.error : string::tformat("HTTP %d", self.status);

// A multipart form field: `value`, or the contents of `file` when that is set.
struct Part
{
	String name;
	String value;
	String file;
}

struct Request
{
	String method;
	String url;
	String[] headers;
	Part[] form;
	String out_file;  // write the body here instead of into Response.body
	long timeout;     // seconds
	bool no_redirects;
}

fn Response get(String url, long timeout = 30) => request({ .method = "GET", .url = url, .timeout = timeout });

fn Response download(String url, String file, long timeout = 300)
{
	return request({ .method = "GET", .url = url, .out_file = file, .timeout = timeout });
}

fn Response request(Request req)
{
	Curl* h = curl::easy_init();
	if (!h) return { .error = "cannot initialise curl" };
	defer curl::easy_cleanup(h);

	Sink sink;
	sink.buf.tinit();
	if (req.out_file.len)
	{
		File? f = file::open(req.out_file, "wb");
		if (catch f) return { .error = string::tformat("cannot write %s", req.out_file) };
		sink.file = f;
		sink.to_file = true;
	}
	defer if (sink.to_file) (void)sink.file.close();

	CurlSlist* headers;
	defer if (headers) curl::slist_free_all(headers);
	foreach (hdr : req.headers) headers = curl::slist_append(headers, hdr.zstr_tcopy());

	char[256] err;
	curl::easy_setopt(h, CurlOption.URL, req.url.zstr_tcopy());
	curl::easy_setopt(h, CurlOption.CUSTOMREQUEST, req.method.zstr_tcopy());
	curl::easy_setopt(h, CurlOption.USERAGENT, "c3l");
	curl::easy_setopt(h, CurlOption.HTTPHEADER, headers);
	curl::easy_setopt(h, CurlOption.FOLLOWLOCATION, req.no_redirects ? 0L : 1L);
	curl::easy_setopt(h, CurlOption.NOPROGRESS, 0L);
	curl::easy_setopt(h, CurlOption.XFERINFOFUNCTION, &on_progress);
	curl::easy_setopt(h, CurlOption.WRITEFUNCTION, &on_write);
	curl::easy_setopt(h, CurlOption.WRITEDATA, &sink);
	curl::easy_setopt(h, CurlOption.HEADERFUNCTION, &on_header);
	curl::easy_setopt(h, CurlOption.HEADERDATA, &sink);
	curl::easy_setopt(h, CurlOption.ERRORBUFFER, &err);
	curl::easy_setopt(h, CurlOption.NOSIGNAL, 1L);
	curl::easy_setopt(h, CurlOption.CONNECTTIMEOUT, 15L);
	$if env::WIN32:  // Schannel fails when it cannot reach a revocation list; downloads are checked by sha256
		curl::easy_setopt(h, CurlOption.SSL_OPTIONS, SSLOPT_REVOKE_BEST_EFFORT);
	$endif
	$if env::LINUX:  // the release links libcurl statically: it does not know where this system keeps them
		String ca = ca_bundle();
		if (ca.len) curl::easy_setopt(h, CurlOption.CAINFO, ca.zstr_tcopy());
	$endif
	curl::easy_setopt(h, CurlOption.TIMEOUT, req.timeout);

	CurlMime* mime;
	defer if (mime) curl::mime_free(mime);
	if (req.form.len)
	{
		mime = curl::mime_init(h);
		foreach (part : req.form)
		{
			CurlMimePart* p = curl::mime_addpart(mime);
			curl::mime_name(p, part.name.zstr_tcopy());
			if (!part.file.len)
			{
				curl::mime_data(p, part.value.ptr, part.value.len);
				continue;
			}
			if (curl::mime_filedata(p, part.file.zstr_tcopy()) != CurlResult.OK)
			{
				return { .error = string::tformat("cannot read %s", part.file) };
			}
			curl::mime_type(p, "application/zip");
		}
		curl::easy_setopt(h, CurlOption.MIMEPOST, mime);
	}

	CurlResult res = curl::easy_perform(h);
	if (catch sys::check_interrupt()) return { .error = "interrupted" };
	if (sink.failed) return { .error = sink.to_file ? string::tformat("cannot write %s", req.out_file) : "response too large" };
	if (res != CurlResult.OK)
	{
		String why = ((ZString)&err).str_view();
		return { .error = why.len ? why.tcopy() : ((ZString)curl::easy_strerror(res)).str_view().tcopy() };
	}
	CLong status;
	curl::easy_getinfo(h, CurlInfoType.RESPONSE_CODE, &status);
	return { .status = (int)status, .body = sink.buf.str_view(), .retry_after = sink.retry_after };
}

struct Sink @private
{
	DString buf;
	File file;
	bool to_file;
	bool failed;
	String retry_after;
}

fn usz on_header(char* ptr, usz size, usz nmemb, void* userdata) @private
{
	Sink* sink = userdata;
	String line = (String)ptr[:size * nmemb];
	if (line.len > 12 && line[:12].to_lower_tcopy() == "retry-after:")
	{
		sink.retry_after = line[12..].trim().tcopy();
	}
	return size * nmemb;
}

<*
 The CA certificates of this Linux system: $SSL_CERT_FILE, else the first of
 the places distributions keep them (the list Go uses); empty if none.
*>
fn String ca_bundle() @private @feat(LINUX)
{
	if (try f = env::tget_var("SSL_CERT_FILE")) return f;
	foreach (f : CA_BUNDLES) if (file::exists(f)) return f;
	return "";
}

const String[] CA_BUNDLES @private @feat(LINUX) = {
	"/etc/ssl/certs/ca-certificates.crt",                 // Debian, Ubuntu, Arch, Gentoo
	"/etc/pki/tls/certs/ca-bundle.crt",                   // Fedora, RHEL
	"/etc/ssl/ca-bundle.pem",                             // openSUSE
	"/etc/pki/tls/cacert.pem",                            // OpenELEC
	"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",  // CentOS, RHEL 7
	"/etc/ssl/cert.pem",                                  // Alpine
};

// Called while a transfer runs: non-zero aborts it.
fn int on_progress(void* data, CurlOff dltotal, CurlOff dlnow, CurlOff ultotal, CurlOff ulnow) @private
{
	return sys::interrupted ? 1 : 0;
}

fn usz on_write(char* ptr, usz size, usz nmemb, void* userdata) @private
{
	Sink* sink = userdata;
	usz n = size * nmemb;
	if (sink.to_file)
	{
		if (catch sink.file.write(ptr[:n])) sink.failed = true;
		return sink.failed ? 0 : n;
	}
	if ((usz)sink.buf.len() + n > MAX_BODY)
	{
		sink.failed = true;
		return 0;
	}
	sink.buf.append(ptr[:n]);
	return n;
}
