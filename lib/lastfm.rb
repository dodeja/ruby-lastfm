require 'lastfm/response'
require 'lastfm/method_category'

require 'lastfm/method_category/auth'
require 'lastfm/method_category/track'
require 'lastfm/method_category/scrobble'

require 'rubygems'
require 'digest/md5'
require 'httparty'
require "addressable/uri"

class BadAuthError < StandardError; end
class BadSessionError < StandardError; end
class BadTimeError < StandardError; end
class ClientBannedError < StandardError; end
class RequestFailedError < StandardError; end

class Lastfm
  API_ROOT = 'http://ws.audioscrobbler.com/2.0'
  API_ROOT_POST = 'http://post.audioscrobbler.com:80/'
  SUBMISSION_PORT = 80
  SUBMISSION_VERSION = '1.2.1'
  @@client_id = 'mgs'
  @@client_ver = '1.0'
  @@default_options = {
    :handshake_on_init => true
  }

  include HTTParty
  base_uri API_ROOT

  attr_accessor :session

  class Error < StandardError; end
  class ApiError < Error; end

  def initialize(api_key, api_secret)
    @api_key = api_key
    @api_secret = api_secret
  end

  def auth
    Auth.new(self)
  end

  def track
    Track.new(self)
  end

  def scrobble
    Scrobble.new(self)
  end
  
  def handshake(user, session)
    ts = Time.now.to_i.to_s
    auth_token = Digest::MD5.hexdigest(@api_secret + ts)
    params = {
      :hs => 'true',
      :p => SUBMISSION_VERSION,
      :c => @@client_id,
      :v => @@client_ver,
      :u => user,
      :t => ts,
      :a => auth_token,
      :api_key => @api_key,
      :sk => session
    }
    uri = Addressable::URI.parse(API_ROOT_POST)
    uri.query_values = params
    response = HTTParty.get(uri)
    res = response.body.split("\n")
    if res[0] == 'OK'
      # Handshake done, parse and return information
      @session_id = res[1]
      @now_playing_url = res[2]
      @submission_url = res[3]
    elsif res[0] == 'BANNED'
      # This indicates that this client version has been banned from the
      # server. This usually happens if the client is violating the protocol
      # in a destructive way. Users should be asked to upgrade their client
      # application.
      raise ClientBannedError, 'Please update your client to a newer version.'
    elsif res[0] == 'BADAUTH'
      # This indicates that the authentication details provided were incorrect. 
      # The client should not retry the handshake until the user has changed 
      # their details
      raise BadAuthError
    elsif res[0] == 'BADTIME'
      # The timestamp provided was not close enough to the current time. 
      # The system clock must be corrected before re-handshaking.
      raise BadTimeError, "Not close enough to current time: #{ts}"
    else
      # This indicates a temporary server failure. The reason indicates the
      # cause of the failure. The client should proceed as directed in the
      # failure handling section
      raise RequestFailedError, res[0]
    end
    res
  end

  def now_playing(u, options = {})
    params = {
      's' => options[:session],
      't' => options[:track],
      'a' => options[:artist],
      'b' => options[:album] || '',
      'l' => options[:length] || '',
      'n' => options[:number] || '',
      'm' => ''
    }
    uri = Addressable::URI.parse(u)
    uri.query_values = params
    response = HTTParty.post(uri)
    res = response.body.split("\n")
      
    if res[0] == 'BADSESSION'
      raise BadSessionError
    end
  end

  def submission(u, options = {})
    params = {
      's' => options[:session],
      'a' => [options[:artist]],
      't' => [options[:track]],
      'i' => [options[:started]],
      'o' => [options[:source] || 'P'],
      'r' => [options[:rating] || ''],
      'l' => [options[:length] || ''],
      'b' => [''],
      'n' => [''],
      'm' => ['']
    }
    uri = Addressable::URI.parse(u)
    uri.query_values = params
    response = HTTParty.post(uri)
    res = response.body.split("\n")
    if res[0] == 'BADSESSION'
      raise BadSessionError
    end
  end


  def request(method, params = {}, http_method = :get, with_signature = false, with_session = false)
    params[:method] = method
    params[:api_key] = @api_key

    # http://www.lastfm.jp/group/Last.fm+Web+Services/forum/21604/_/497978
    #params[:format] = format

    params.update(:sk => @session) if with_session
    params.update(:api_sig => Digest::MD5.hexdigest(build_method_signature(params))) if with_signature
    params.update(:format => 'json')

    response = Response.new(self.class.send(http_method, '/', (http_method == :post ? :body : :query) => params).body)
    unless response.success?
      raise ApiError.new(response.message)
    end

    response
  end

  private

  def build_method_signature(params)
    params.to_a.sort_by do |param|
      param.first.to_s
    end.inject('') do |result, param|
      result + param.join('')
    end + @api_secret
  end
end
