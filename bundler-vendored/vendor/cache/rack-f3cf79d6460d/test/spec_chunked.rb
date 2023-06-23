# frozen_string_literal: true

require 'minitest/global_expectations/autorun'
require 'rack/chunked'
require 'rack/lint'
require 'rack/mock'

describe Rack::Chunked do
  def chunked(app)
    proc do |env|
      app = Rack::Chunked.new(app)
      response = Rack::Lint.new(app).call(env)
      # we want to use body like an array, but it only has #each
      response[2] = response[2].to_enum.to_a
      response
    end
  end

  before do
    @env = Rack::MockRequest.
      env_for('/', 'SERVER_PROTOCOL' => 'HTTP/1.1', 'REQUEST_METHOD' => 'GET')
  end

  class TrailerBody
    def each(&block)
      ['Hello', ' ', 'World!'].each(&block)
    end

    def trailers
      { "Expires" => "tomorrow" }
    end
  end

  it 'yields trailer headers after the response' do
    app = lambda { |env|
      [200, { "Content-Type" => "text/plain", "Trailer" => "Expires" }, TrailerBody.new]
    }
    response = Rack::MockResponse.new(*chunked(app).call(@env))
    response.headers.wont_include 'Content-Length'
    response.headers['Transfer-Encoding'].must_equal 'chunked'
    response.body.must_equal "5\r\nHello\r\n1\r\n \r\n6\r\nWorld!\r\n0\r\nExpires: tomorrow\r\n\r\n"
  end

  it 'chunk responses with no Content-Length' do
    app = lambda { |env| [200, { "Content-Type" => "text/plain" }, ['Hello', ' ', 'World!']] }
    response = Rack::MockResponse.new(*chunked(app).call(@env))
    response.headers.wont_include 'Content-Length'
    response.headers['Transfer-Encoding'].must_equal 'chunked'
    response.body.must_equal "5\r\nHello\r\n1\r\n \r\n6\r\nWorld!\r\n0\r\n\r\n"
  end

  it 'chunks empty bodies properly' do
    app = lambda { |env| [200, { "Content-Type" => "text/plain" }, []] }
    response = Rack::MockResponse.new(*chunked(app).call(@env))
    response.headers.wont_include 'Content-Length'
    response.headers['Transfer-Encoding'].must_equal 'chunked'
    response.body.must_equal "0\r\n\r\n"
  end

  it 'chunks encoded bodies properly' do
    body = ["\uFFFEHello", " ", "World"].map {|t| t.encode("UTF-16LE") }
    app  = lambda { |env| [200, { "Content-Type" => "text/plain" }, body] }
    response = Rack::MockResponse.new(*chunked(app).call(@env))
    response.headers.wont_include 'Content-Length'
    response.headers['Transfer-Encoding'].must_equal 'chunked'
    response.body.encoding.to_s.must_equal "ASCII-8BIT"
    response.body.must_equal "c\r\n\xFE\xFFH\x00e\x00l\x00l\x00o\x00\r\n2\r\n \x00\r\na\r\nW\x00o\x00r\x00l\x00d\x00\r\n0\r\n\r\n".dup.force_encoding("BINARY")
    response.body.must_equal "c\r\n\xFE\xFFH\x00e\x00l\x00l\x00o\x00\r\n2\r\n \x00\r\na\r\nW\x00o\x00r\x00l\x00d\x00\r\n0\r\n\r\n".dup.force_encoding(Encoding::BINARY)
  end

  it 'not modify response when Content-Length header present' do
    app = lambda { |env|
      [200, { "Content-Type" => "text/plain", 'Content-Length' => '12' }, ['Hello', ' ', 'World!']]
    }
    status, headers, body = chunked(app).call(@env)
    status.must_equal 200
    headers.wont_include 'Transfer-Encoding'
    headers.must_include 'Content-Length'
    body.join.must_equal 'Hello World!'
  end

  it 'not modify response when client is HTTP/1.0' do
    app = lambda { |env| [200, { "Content-Type" => "text/plain" }, ['Hello', ' ', 'World!']] }
    @env['SERVER_PROTOCOL'] = 'HTTP/1.0'
    status, headers, body = chunked(app).call(@env)
    status.must_equal 200
    headers.wont_include 'Transfer-Encoding'
    body.join.must_equal 'Hello World!'
  end

  it 'not modify response when client is ancient, pre-HTTP/1.0' do
    app = lambda { |env| [200, { "Content-Type" => "text/plain" }, ['Hello', ' ', 'World!']] }
    check = lambda do
      status, headers, body = chunked(app).call(@env.dup)
      status.must_equal 200
      headers.wont_include 'Transfer-Encoding'
      body.join.must_equal 'Hello World!'
    end

    @env.delete('SERVER_PROTOCOL') # unicorn will do this on pre-HTTP/1.0 requests
    check.call

    @env['SERVER_PROTOCOL'] = 'HTTP/0.9' # not sure if this happens in practice
    check.call
  end

  it 'not modify response when Transfer-Encoding header already present' do
    app = lambda { |env|
      [200, { "Content-Type" => "text/plain", 'Transfer-Encoding' => 'identity' }, ['Hello', ' ', 'World!']]
    }
    status, headers, body = chunked(app).call(@env)
    status.must_equal 200
    headers['Transfer-Encoding'].must_equal 'identity'
    body.join.must_equal 'Hello World!'
  end

  [100, 204, 304].each do |status_code|
    it "not modify response when status code is #{status_code}" do
      app = lambda { |env| [status_code, {}, []] }
      status, headers, _ = chunked(app).call(@env)
      status.must_equal status_code
      headers.wont_include 'Transfer-Encoding'
    end
  end
end