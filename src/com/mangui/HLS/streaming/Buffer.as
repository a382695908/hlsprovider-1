package com.mangui.HLS.streaming {


    import com.mangui.HLS.*;
    import com.mangui.HLS.muxing.*;
    import com.mangui.HLS.streaming.*;
    import com.mangui.HLS.parsing.*;
    import com.mangui.HLS.utils.*;
    
    import flash.media.*;
    import flash.net.*;
    import flash.utils.*;


    /** Class that keeps the buffer filled. **/
    public class Buffer {


        /** Default bufferlength in seconds. **/
        private static const LENGTH:Number = 30;

        /** Default bufferlength in seconds. **/
        private var restart_length:Number = 8;

        /** Reference to the framework controller. **/
        private var _hls:HLS;
        /** The buffer with video tags. **/
        private var _buffer:Vector.<Tag>;
        /** NetConnection legacy stuff. **/
        private var _connection:NetConnection;
        /** The current quality level. **/
        private var _level:Number = 0;
        /** Reference to the manifest levels. **/
        private var _levels:Array;
        /** The fragment loader. **/
        private var _loader:Loader;
        /** Store that a fragment load is in progress. **/
        private var _loading:Boolean;
        /** Interval for checking buffer and position. **/
        private var _interval:Number;
        /** Next loading fragment sequence number. **/
        private var _next_seqnum:Number;
        /** The start position of the stream. **/
        public var PlaybackStartPosition:Number = 0;
         /** start play time **/
        private var _playback_start_time:Number;
        /** playback start PTS. **/
        private var _playback_start_pts:Number;
        /** Current play time (time since beginning of playback) **/
        private var _playback_current_time:Number;
        /** Current play position (relative position from beginning of sliding window) **/
        private var _playback_current_position:Number;
        /** buffer last PTS. **/
        private var _buffer_last_pts:Number;
         /** next buffer time. **/
        private var _buffer_next_time:Number;
        /** Current playback state. **/
        private var _state:String;
        /** Netstream instance used for playing the stream. **/
        private var _stream:NetStream;
        /** The last tag that was appended to the buffer. **/
        private var _tag:Number;
        /** soundtransform object. **/
        private var _transform:SoundTransform;
        /** Reference to the video object. **/
        private var _video:Object;
      /** Keeps track of the first PTS value for each sequence number **/
      private var _ptsArray:Array;


        /** Create the buffer. **/
        public function Buffer(hls:HLS, loader:Loader, video:Object):void {
            _hls = hls;
            _loader = loader;
            _video = video;
            _hls.addEventListener(HLSEvent.MANIFEST,_manifestHandler);
            _connection = new NetConnection();
            _connection.connect(null);
            _transform = new SoundTransform();
            _transform.volume = 0.9;
            _setState(HLSStates.IDLE);
            _ptsArray = new Array();
        };


        /** Check the bufferlength. **/
        private function _checkBuffer():void {
            var reachedend:Boolean = false;
            var buffer:Number = 0;
            // Calculate the buffer and position.
            if(_buffer.length) {
               buffer = (_buffer_last_pts - _playback_start_pts)/1000 - _stream.time;
               _playback_current_time = (Math.round(_stream.time*100 + _playback_start_time*100)/100);
               var play_position:Number = _playback_current_time-(_ptsArray[_levels[_level].start_seqnum]-_playback_start_pts)/1000;
               
               if(play_position != _playback_current_position) {
                  if (play_position <0) {
                     play_position = 0;
                  }
                  _playback_current_position = play_position;
                  _hls.dispatchEvent(new HLSEvent(HLSEvent.MEDIA_TIME,{ position:_playback_current_position, buffer:buffer, duration:_levels[0].duration}));
               }
            }
            
            // Load new tags from fragment.
            if(buffer < Buffer.LENGTH && !_loading) {
               var loadstatus:Number = _loader.loadfragment(_next_seqnum,buffer,_loaderCallback,(_buffer.length == 0));
               if (loadstatus == 0) {
                  // good, new fragment being loaded
                  _loading = true;
               } else  if (loadstatus < 0) {
                  /* it means sequence number requested is smaller than any seqnum available. 
                     it could happen on live playlist in 2 scenarios :
                     if bandwidth available is lower than lowest quality needed bandwidth
                     after long pause
                     => call seek(0) to force a restart of the playback session */
                  seek(0);
                  return;
               } else if(loadstatus > 0) {
                  //seqnum not available in playlist
                  if (_hls.getType() == HLSTypes.VOD) {
                     // if VOD playlist, it means we reached the end, on live playlist do nothing and wait ...
                     reachedend = true;
                  }
               }
            }
            // Append tags to buffer.
            if((_state == HLSStates.PLAYING && _stream.bufferLength < Buffer.LENGTH / 3) || 
               (_state == HLSStates.BUFFERING && buffer > restart_length))
             {
                //Log.txt("appending data");
                while(_tag < _buffer.length && _stream.bufferLength < Buffer.LENGTH * 2 / 3) {
                    if(_buffer[_tag].type == Tag.AVC_HEADER && _buffer[_tag].level != _level) {
                        _level = _buffer[_tag].level;
                    }
                    try {
                        _stream.appendBytes(_buffer[_tag].data);
                    } catch (error:Error) {
                        _errorHandler(new Error(_buffer[_tag].type+": "+ error.message));
                    }
                    // Last tag done? Then append sequence end.
                    if (reachedend ==true && _tag == _buffer.length - 1) {
                        _stream.appendBytesAction(NetStreamAppendBytesAction.END_SEQUENCE);
                        _stream.appendBytes(new ByteArray());
                    }
                    _tag++;
                }
            }
            // Set playback state and complete.
            if(_stream.bufferLength < Buffer.LENGTH / 10) {
                if(reachedend ==true) {
                    if(_stream.bufferLength == 0) {
                        _complete();
                    }
                } else if(_state == HLSStates.PLAYING) {
                    _setState(HLSStates.BUFFERING);
                }
            } else if (_state == HLSStates.BUFFERING) {
                _setState(HLSStates.PLAYING);
            }
        };


        /** The video completed playback. **/
        private function _complete():void {
            _setState(HLSStates.IDLE);
            clearInterval(_interval);
            // _stream.pause();
            _hls.dispatchEvent(new HLSEvent(HLSEvent.COMPLETE));
        };


        /** Dispatch an error to the controller. **/
        private function _errorHandler(error:Error):void { 
            _hls.dispatchEvent(new HLSEvent(HLSEvent.ERROR,error.toString()));
        };


        /** Return the current playback state. **/
        public function getPosition():Number {
            return _playback_current_position;
        };


        /** Return the current playback state. **/
        public function getState():String {
            return _state;
        };


        /** Add a fragment to the buffer. **/
        private function _loaderCallback(tags:Vector.<Tag>,min_pts:Number,max_pts:Number):void {
            _buffer = _buffer.slice(_tag);
            _tag = 0;
            if (_ptsArray.length == 0) {
               _playback_start_pts = min_pts;
            }
            _buffer_last_pts = max_pts;
            _ptsArray[tags[0].seqnum] = min_pts;
            tags.sort(_sortTagsbyDTS);
            for each (var t:Tag in tags) {
               _buffer.push(t);
            }
            _buffer_next_time=(_buffer_last_pts-_playback_start_pts)/1000;
            Log.txt("_loaderCallback,_buffer_next_time:"+ _buffer_next_time);
            _next_seqnum++;
            _loading = false;
        };

        /** Start streaming on manifest load. **/
        private function _manifestHandler(event:HLSEvent):void {
            if(_state == HLSStates.IDLE) {
                _levels = event.levels;
                _stream = new NetStream(_connection);
                _video.attachNetStream(_stream);
                _stream.play(null);
                _stream.soundTransform = _transform;
                _stream.appendBytesAction(NetStreamAppendBytesAction.RESET_BEGIN);
                _stream.appendBytes(FLV.getHeader());
                _level = 0;
                seek(PlaybackStartPosition);
            }
        };


        /** Toggle playback. **/
        public function pause():void {
            clearInterval(_interval);
            if(_state == HLSStates.PAUSED) { 
                _setState(HLSStates.BUFFERING);
                _stream.resume();
                _interval = setInterval(_checkBuffer,100);
            } else if(_state == HLSStates.PLAYING) {
                _setState(HLSStates.PAUSED);
                _stream.pause();
            }
        };

        /** Change playback state. **/
        private function _setState(state:String):void {
            if(state != _state) {
                _state = state;
                _hls.dispatchEvent(new HLSEvent(HLSEvent.STATE,_state));
            }
        };


        /** Sort the buffer by tag. **/
        private function _sortTagsbyDTS(x:Tag,y:Tag):Number {
            if(x.dts < y.dts) {
                return -1;
            } else if (x.dts > y.dts) {
                return 1;
            } else {
                if(x.type == Tag.AVC_HEADER || x.type == Tag.AAC_HEADER) {
                    return -1;
                } else if (y.type == Tag.AVC_HEADER || y.type == Tag.AAC_HEADER) {
                    return 1;
                } else {
                    if(x.type == Tag.AVC_NALU) {
                        return -1;
                    } else if (y.type == Tag.AVC_NALU) {
                        return 1;
                    } else {
                        return 0;
                    }
                }
            }
        };

        /** Start playing data in the buffer. **/
        public function seek(position:Number):void {
            if(_levels.length) {
               _buffer = new Vector.<Tag>();
               _ptsArray = new Array();
               _loader.clearLoader();
               _loading = false;
               _tag = 0;
                PlaybackStartPosition = position;
               _stream.seek(0);
               _stream.appendBytesAction(NetStreamAppendBytesAction.RESET_SEEK);
               var frag:Fragment = _levels[_level].getFragmentfromPosition(position);
               _next_seqnum = frag.seqnum;
               _playback_start_time = frag.start;
               _buffer_next_time = _playback_start_time;
               _setState(HLSStates.BUFFERING);
               clearInterval(_interval);
               _interval = setInterval(_checkBuffer,100);
            }
        };


        /** Stop playback. **/
        public function stop():void {
            if(_stream) {
                _stream.pause();
            }
            _loading = false;
            clearInterval(_interval);
            _levels = [];
            _setState(HLSStates.IDLE);
        };


        /** Change the volume (set in the NetStream). **/
        public function volume(percent:Number):void {
            _transform.volume = percent/100;
            if(_stream) {
                _stream.soundTransform = _transform;
            }
        };


    }


}