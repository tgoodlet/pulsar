from http.client import responses
from http.cookies import SimpleCookie
from datetime import datetime, timedelta
from functools import reduce

from multidict import CIMultiDict

from wsgi cimport _http_date


cdef object nocache = object()


def wsgi_cached(method):
    cdef str name = method.__name__

    def _(self):
        cache = self.environ[PULSAR_CACHE]
        value = getattr(cache, name, nocache)
        if value is nocache:
            setattr(cache, name, method(self))
            value = getattr(cache, name)
        return value

    return property(_, doc=method.__doc__)


cdef class WsgiResponse:
    cdef public:
        dict environ
        int status_code
        str encoding
        object headers, can_store_cookies, __wsgi_started__
    cdef object _content, _cookies
    cdef int _iterated

    def __cinit__(self, int status_code=200, dict environ=None,
                  object content=None, object response_headers=None,
                  str content_type=None, str encoding=None,
                  object can_store_cookies=True):
        self.environ = environ
        self.status_code = status_code
        self.encoding = encoding
        self.can_store_cookies = can_store_cookies
        self.headers = CIMultiDict(response_headers or ())
        self._content = get_content(self, content)
        if content_type:
            self.headers['content-type'] = content_type

    @property
    def content(self):
        return self._content

    @content.setter
    def content(self, content):
        if not self._iterated:
            self._content = get_content(self, content)
        else:
            raise RuntimeError('Cannot set content. Already iterated')

    @property
    def content_type(self):
        return self.headers.get(CONTENT_TYPE)

    @content_type.setter
    def content_type(self, typ):
        if typ:
            self.headers[CONTENT_TYPE] = typ
        else:
            self.headers.pop(CONTENT_TYPE, None)

    @property
    def status(self):
        return '%s %s' % (self.status_code, responses.get(self.status_code))

    @property
    def cookies(self):
        if self._cookies is None:
            self._cookies = SimpleCookie()
        return self._cookies

    cpdef object start(self, object start_response):
        assert not self.__wsgi_started__
        self.__wsgi_started__ = True
        return start_response(self.status, self.get_headers())

    def __iter__(self):
        if self._iterated:
            raise RuntimeError('WsgiResponse can be iterated once only')
        self.__wsgi_started__ = True
        self._iterated = True
        return iter(self._content)

    def set_cookie(self, key, **kwargs):
        """
        Sets a cookie.
        ``expires`` can be a string in the correct format or a
        ``datetime.datetime`` object in UTC. If ``expires`` is a datetime
        object then ``max_age`` will be calculated.
        """
        set_cookie(self.cookies, key, **kwargs)

    def delete_cookie(self, key, path='/', domain=None):
        set_cookie(self.cookies, key, max_age=0, path=path, domain=domain,
                   expires='Thu, 01-Jan-1970 00:00:00 GMT')

    cpdef object get_headers(self):
        """The list of headers for this response
        """
        cdef headers = self.headers
        cdef int status = self.status_code
        cdef int cl
        cdef str ct

        if status == 204 or status == 304 or 100 <= status < 200:
            headers.pop(CONTENT_TYPE, None)
            headers.pop(CONTENT_LENGTH, None)
            self._content = ()
        else:
            try:
                len(self._content)
            except TypeError:
                pass
            else:
                cl = reduce(count_len, self._content, 0)
                headers[CONTENT_LENGTH] = str(cl)
            ct = headers.get(CONTENT_TYPE)
            # content type encoding available
            if self.encoding:
                ct = ct or 'text/plain'
                if ';' not in ct:
                    ct = '%s; charset=%s' % (ct, self.encoding)
                headers[CONTENT_TYPE] = ct
            if self.environ and self.environ['REQUEST_METHOD'] == 'HEAD':
                self._content = ()
        # Cookies
        if (self.status_code < 400 and self.can_store_cookies and
                self._cookies):
            for c in self.cookies.values():
                headers.add_header(SET_COOKIE, c.OutputString())
        return headers.items()

    cpdef void close(self):
        """Close this response, required by WSGI
        """
        if hasattr(self._content, 'close'):
            self._content.close()


cdef object get_content(self, object content):
    if content is None:
        return ()
    else:
        if isinstance(content, str):
            if not self.encoding:   # use utf-8 if not set
                self.encoding = 'utf-8'
            return content.encode(self.encoding),

        elif isinstance(content, bytes):
            return content,

        return content


cdef int count_len(int a, object b):
    return a + len(b)


cpdef set_cookie(cookies, key, value='', max_age=None, expires=None, path='/',
                  domain=None, secure=False, httponly=False):
    '''Set a cookie key into the cookies dictionary *cookies*.'''
    cookies[key] = value
    if expires is not None:
        if isinstance(expires, datetime):
            now = (expires.now(expires.tzinfo) if expires.tzinfo else
                   expires.utcnow())
            delta = expires - now
            # Add one second so the date matches exactly (a fraction of
            # time gets lost between converting to a timedelta and
            # then the date string).
            delta = delta + timedelta(seconds=1)
            # Just set max_age - the max_age logic will set expires.
            expires = None
            max_age = max(0, delta.days * 86400 + delta.seconds)
        else:
            cookies[key]['expires'] = expires
    if max_age is not None:
        cookies[key]['max-age'] = max_age
        # IE requires expires, so set it if hasn't been already.
        if not expires:
            cookies[key]['expires'] = _http_date(_current_time_ + max_age)
    if path is not None:
        cookies[key]['path'] = path
    if domain is not None:
        cookies[key]['domain'] = domain
    if secure:
        cookies[key]['secure'] = True
    if httponly:
        cookies[key]['httponly'] = True