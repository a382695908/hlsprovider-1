package org.mangui.HLS.muxing {
	
	
	import org.mangui.HLS.muxing.*;
   import org.mangui.HLS.utils.Log;
   import org.mangui.HLS.HLSAudioTrack;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.TimerEvent;
	import flash.utils.ByteArray;
	import flash.utils.Timer;
	
	
	/** Representation of an MPEG transport stream. **/
	public class TS extends EventDispatcher {
		
		
    /** TS Sync byte. **/
    private static const SYNCBYTE:uint = 0x47;
    /** TS Packet size in byte. **/
    private static const PACKETSIZE:uint = 188;
    /** loop counter to avoid blocking **/
    private static const COUNT:uint = 5000;
    /** Packet ID of the PAT (is always 0). **/
    private static const _patId:Number = 0;
    /** Packet ID of the SDT (is always 17). **/
    private static const _sdtId:Number = 17;
    /** has PAT been parsed ? **/
    private var _patParsed:Boolean= false;
    /** has PMT been parsed ? **/
    private var _pmtParsed:Boolean= false;
    /** any TS packets before PMT ? **/
    private var _packetsBeforePMT:Boolean = false;
    /** are we in fallback PID parsing mode ? **/
    private var _fallbackMode:Boolean= false;
    /** Packet ID of the Program Map Table. **/
    private var _pmtId:Number = -1;
    /** Packet ID of the video stream. **/
    private var _avcId:Number = -1;
    /** Packet ID of selected audio stream. **/
    private var _audioId:Number = -1;
    private var _audioIsAAC:Boolean = false;
    /** should we extract audio ? **/
    private var _audioExtract:Boolean;
    /** List of AAC and MP3 audio PIDs */
    private var _aacIds:Vector.<uint> = new Vector.<uint>();
    private var _mp3Ids:Vector.<uint> = new Vector.<uint>();
    /** fallback Packet ID of the video stream. **/
    private static var _avcFallbackId:Number = -1;
    /** fallback Packet ID of audio stream. **/
    private static var _audioFallbackId:Number = -1;
    /** fallback Packet ID of the MP3 audio stream. **/
    private static var _audioFallbackIsAAC:Boolean= false;
    /** List of packetized elementary streams with AAC. **/
    private var _audioPES:Vector.<PES> = new Vector.<PES>();
    /** List of packetized elementary streams with AVC. **/
    private var _videoPES:Vector.<PES> = new Vector.<PES>();
    /** List with audio frames. **/
    private var _audioTags:Vector.<Tag> = new Vector.<Tag>();
    /** List with video frames. **/
    private var _videoTags:Vector.<Tag> = new Vector.<Tag>();
    /** Timer for reading packets **/ 
    private var _timer:Timer;
    /** Byte data to be read **/
    private var _data:ByteArray;
    /* last PES packet containing AVCC Frame (SPS/PPS) */
    private var _lastAVCCFrame:PES = null;
    /* callback function upon read complete */
    private var _callback:Function;
		
		
    public static function probe(data:ByteArray):Boolean {
      var pos:Number = data.position;
      var len:Number = Math.min(data.bytesAvailable,188*2);
      for(var i:Number = 0; i < len ; i++) {
        if(data.readByte() == SYNCBYTE) {
          // ensure that at least two consecutive TS start offset are found
          if(data.bytesAvailable > 188) {
            data.position = pos+i+188;
            if(data.readByte() == SYNCBYTE) {
              data.position = pos+i;
              return true;
            } else {
              data.position = pos+i+1;
            }
          }
        }
      }
      data.position = pos;
      return false;
    }

      /** Transmux the M2TS file into an FLV file. **/
      public function TS(data:ByteArray,callback:Function,audioExtract:Boolean,audioPID:Number) {
         // Extract the elementary streams.
         _data = data;
         _callback = callback;
         _timer = new Timer(0,0);
         _timer.addEventListener(TimerEvent.TIMER, _readData);
         _timer.start();
         _audioId = audioPID;
         _audioExtract = audioExtract;
      };
		
		/** append new TS data */
		//public function appendData(newData:ByteArray):void {
		//  newData.readBytes(_data,_data.length);
		//  _timer.start();
		//}
		
    /** Read a small chunk of packets each time to avoid blocking **/
    private function _readData(e:Event):void {
      var i:uint = 0;
      while(_data.bytesAvailable && i < COUNT) {
        _readPacket();
        i++;
        
      }
      // finish reading TS fragment
      if (!_data.bytesAvailable) {
        // first check if TS parsing was successful
        if(_pmtParsed == false && _fallbackMode == false) {
          // if parsing not successful, try to reparse segment will fallback A/V PIDs if any
          Log.error("TS: no PMT found, trying to reparse using fallback PIDs");
          if(_audioFallbackId !=-1 || _avcFallbackId != -1)  {
             _data.position = 0;
             _audioId = _audioFallbackId;
             _audioIsAAC = _audioFallbackIsAAC;
             _avcId = _avcFallbackId;
             _fallbackMode = true;
          } else {
            Log.error("TS: no fallback PIDs available, report parsing error");
            _callback(null,null,null,null);
          }
        } else {
          _timer.stop();
           if (_videoPES.length == 0 && _audioPES.length == 0 ) {
            Log.error("No audio or video streams found.");
            _callback(null,null,null,null);
           } else {
            _extractFrames();
          }
        }
      }
    }

    /** setup the video and audio tag vectors from the read data **/
    private function _extractFrames():void {
      Log.debug("TS: successfully parsed");
      // report current audio track and audio track list
      var audioList:Vector.<HLSAudioTrack> = new Vector.<HLSAudioTrack>();
      // Extract the ADTS or MP3 audio frames (transform PES packets into audio tags)
      if(_audioId > 0) {
        if(_audioIsAAC) {
          Log.debug("TS: extracting AAC tags");
          _readADTS();
        } else {
          Log.debug("TS: extracting MP3 tags");
          _readMPEG();
        }
        
        var isDefault:Boolean = true;
        
        for (var i:Number=0; i<_aacIds.length; ++i) {
          audioList.push(new HLSAudioTrack('TS/AAC ' + i, HLSAudioTrack.FROM_DEMUX,_aacIds[i],isDefault));
          if(isDefault)
            isDefault = false;
        }
        for (i=0; i<_mp3Ids.length; ++i) {
          audioList.push(new HLSAudioTrack('TS/MP3 ' + i, HLSAudioTrack.FROM_DEMUX,_mp3Ids[i],isDefault));
          if(isDefault)
            isDefault = false;
        }
      }
      Log.debug("TS: " + _audioTags.length + " audio tags extracted");
      
      // Extract the NALU video frames (transform PES packets into video tags)
      if (_avcId > 0) {
        Log.debug("TS: extracting AVC tags");
        _readNALU();
        Log.debug("TS: " + _videoTags.length + " video tags extracted");
      }
      Log.debug("TS: all tags extracted, callback demux");
      _callback(_audioTags,_videoTags,_getADIF(),_getAVCC(),_audioId,audioList);
    }
		
		/** Get audio configuration data. **/
		private function _getADIF():ByteArray {
			if(_audioId > 0 && _audioIsAAC && _audioTags.length > 0) {
				return AAC.getADIF(_audioPES[0].data,_audioPES[0].payload);
			} else { 
				return new ByteArray();
			}
		};
		
		
		/** Get video configuration data. **/
		private function _getAVCC():ByteArray {
			if(_lastAVCCFrame == null) {
				return new ByteArray();
			}
			return AVC.getAVCC(_lastAVCCFrame.data,_lastAVCCFrame.payload);
		};
		
		
		/** Read ADTS frames from audio PES streams. **/
		private function _readADTS():void {
			var frames:Vector.<AudioFrame>;
			var overflow:Number = 0;
			var tag:Tag;
			var stamp:Number;
			for(var i:Number=0; i<_audioPES.length; i++) {
				// Parse the PES headers.
				_audioPES[i].parse();
				// Correct for Segmenter's "optimize", which cuts frames in half.
				if(overflow > 0) {
					_audioPES[i-1].data.position = _audioPES[i-1].data.length;
					_audioPES[i-1].data.writeBytes(_audioPES[i].data,_audioPES[i].payload,overflow);
					_audioPES[i].payload += overflow;
				}
				// Store ADTS frames in array.
				frames = AAC.getFrames(_audioPES[i].data,_audioPES[i].payload);
				for(var j:Number=0; j< frames.length; j++) {
					// Increment the timestamp of subsequent frames.
					stamp = Math.round(_audioPES[i].pts + j * 1024 * 1000 / frames[j].rate);
					tag = new Tag(Tag.AAC_RAW, stamp, stamp, false);
					if(i == _audioPES.length-1 && j == frames.length - 1) {
					  if((_audioPES[i].data.length - frames[j].start)>0) {
						  tag.push(_audioPES[i].data, frames[j].start, _audioPES[i].data.length - frames[j].start);
					  }
					} else { 
						tag.push(_audioPES[i].data, frames[j].start, frames[j].length);
					}
					_audioTags.push(tag);
				}
				if(frames.length) {
				  // Correct for Segmenter's "optimize", which cuts frames in half.
				  overflow = frames[frames.length-1].start + frames[frames.length-1].length - _audioPES[i].data.length;
			  }
			}
		};
		
		
		/** Read MPEG data from audio PES streams. **/
		private function _readMPEG():void {
			var tag:Tag;
			for(var i:Number=0; i<_audioPES.length; i++) {
				_audioPES[i].parse();
				tag = new Tag(Tag.MP3_RAW, _audioPES[i].pts,_audioPES[i].dts, false);
				tag.push(_audioPES[i].data, _audioPES[i].payload, _audioPES[i].data.length-_audioPES[i].payload);
				_audioTags.push(tag);
			}
		};
		
		
		/** Read NALU frames from video PES streams. **/
		private function _readNALU():void {
			var overflow:Number;
			var units:Vector.<VideoFrame>;
			for(var i:Number=0; i<_videoPES.length; i++) {
				// Parse the PES headers and NAL units.
				try { 
					_videoPES[i].parse();
				} catch (error:Error) {
					Log.error(error.message);
					continue;
				}
				units = AVC.getNALU(_videoPES[i].data,_videoPES[i].payload);
				// If there's no NAL unit, push all data in the previous tag.
				if(!units.length) {
					_videoTags[_videoTags.length-1].push(_videoPES[i].data, _videoPES[i].payload,
						_videoPES[i].data.length - _videoPES[i].payload);
					continue;
				}
				// If NAL units are offset, push preceding data into the previous tag.
				overflow = units[0].start - units[0].header - _videoPES[i].payload;
				if(overflow && _videoTags.length >0) {
					_videoTags[_videoTags.length-1].push(_videoPES[i].data,_videoPES[i].payload,overflow);
				}
				_videoTags.push(new Tag(Tag.AVC_NALU,_videoPES[i].pts,_videoPES[i].dts,false));
				// Only push NAL units 1 to 5 into tag.
				for(var j:Number = 0; j < units.length; j++) {
					if (units[j].type < 6) {
						_videoTags[_videoTags.length-1].push(_videoPES[i].data,units[j].start,units[j].length);
						// Unit type 5 indicates a keyframe.
						if(units[j].type == 5) {
							_videoTags[_videoTags.length-1].keyframe = true;
						}
					} else if (units[j].type == 7 || units[j].type == 8) {
							if(_lastAVCCFrame == null) {
								_lastAVCCFrame=_videoPES[i];
							}
					}
				}
			}
		};
		
		
		/** Read TS packet. **/
		private function _readPacket():void {	
			// Each packet is 188 bytes.
			var todo:uint = TS.PACKETSIZE;
			// Sync byte.
			if(_data.readByte() != TS.SYNCBYTE) {
			  var pos:Number = _data.position;
			  if(probe(_data) == true) {
			    Log.warn("lost sync in TS, between offsets:" + pos + "/" + _data.position);
			    _data.position++;
			  } else {
				  throw new Error("Could not parse TS file: sync byte not found @ offset/len " + _data.position + "/"+ _data.length);
				}
			}
			todo--;
			// Payload unit start indicator.
			var stt:uint = (_data.readUnsignedByte() & 64) >> 6;
			_data.position--;
			
			// Packet ID (last 13 bits of UI16).
			var pid:uint = _data.readUnsignedShort() & 8191;
			// Check for adaptation field.
			todo -=2;
			var atf:uint = (_data.readByte() & 48) >> 4;
			todo --;
			// Read adaptation field if available.
			if(atf > 1) {
				// Length of adaptation field.
				var len:uint = _data.readUnsignedByte();
				todo--;
				// Random access indicator (keyframe).
				//var rai:uint = data.readUnsignedByte() & 64;
				_data.position += len;
				todo -= len;
				// Return if there's only adaptation field.
				if(atf == 2 || len == 183) {
					_data.position += todo;
					return;
				}
			}
			
			var pes:ByteArray = new ByteArray();
			// Parse the PES, split by Packet ID.
			switch (pid) {
				case _patId:
					todo -= _readPAT(stt);
          if (_patParsed == false) {
             _patParsed = true;
             Log.debug("TS: PAT found.PMT PID:" + _pmtId);
          }
					break;
				case _pmtId:
					todo -= _readPMT(stt);
			    if(_pmtParsed == false) {
			      _pmtParsed = true;
			      Log.debug("TS: PMT found.AVC,Audio PIDs:" + _avcId + "," + _audioId);
			    // if PMT was not parsed before, and some unknown packets have been skipped in between, 
			    // rewind to beginning of the stream, it helps recovering bad segmented content
			    // in theory there should be no A/V packets before PAT/PMT)
			      if (_packetsBeforePMT) {
			        Log.warn("late PMT found, rewinding at beginning of TS");
			        _data.position = 0;
			        return;
			      }
		      }
					break;
				case _audioId:
					if(stt) {
						pes.writeBytes(_data,_data.position,todo);
						_audioPES.push(new PES(pes,true));
					} else if (_audioPES.length) {
						_audioPES[_audioPES.length-1].data.writeBytes(_data,_data.position,todo);
					} else {
						Log.warn("Discarding TS audio packet with id "+pid);
					}
					break;
				case _avcId:
					if(stt) {
						pes.writeBytes(_data,_data.position,todo);
						_videoPES.push(new PES(pes,false));
					} else if (_videoPES.length) {
						_videoPES[_videoPES.length-1].data.writeBytes(_data,_data.position,todo);
					} else {
						Log.warn("Discarding TS video packet with id "+pid + " bad TS segmentation ?");
					}
					break;
				case _sdtId:
						break;
				default:
				_packetsBeforePMT=true;
					break;
			}
			// Jump to the next packet.
			_data.position += todo;
		};
		
		
		/** Read the Program Association Table. **/
		private function _readPAT(stt:uint):Number {
			var pointerField:uint = 0;
			if (stt) {
				pointerField = _data.readUnsignedByte();
				// skip alignment padding
				_data.position += pointerField;
			}
			// skip table id
			_data.position += 1;
			// get section length
			var sectionLen:uint = _data.readUnsignedShort() & 0x3FF;
			// Check the section length for a single PMT.
			if (sectionLen > 13) {
				throw new Error("Multiple PMT entries are not supported.");
			}
			// Grab the PMT ID.
			_data.position += 7;
			_pmtId = _data.readUnsignedShort() & 8191;
			return 13 + pointerField;
		};
		
		
		/** Read the Program Map Table. **/
    private function _readPMT(stt:uint):Number {
      var pointerField:uint = 0;

      // reset audio tracks
      var audioFound:Boolean = false;
      _aacIds = new Vector.<uint>();
      _mp3Ids = new Vector.<uint>();

      if (stt) {
        pointerField = _data.readUnsignedByte();
        // skip alignment padding
        _data.position += pointerField;
      }
      // skip table id
      _data.position += 1;
      // Check the section length for a single PMT.
      var len:uint = _data.readUnsignedShort() & 0x3FF;
      var read:uint = 13;
      _data.position += 7;
      // skip program info
      var pil:uint = _data.readUnsignedShort() & 0x3FF;
      _data.position += pil;
      read += pil;
      // reset AVC fallback PIDs before parsing PMT
      _avcFallbackId = -1;
      // Loop through the streams in the PMT.
      while(read < len) {
        // stream type
        var typ:uint = _data.readByte();
        // stream pid
        var sid:uint = _data.readUnsignedShort() & 0x1fff;
        if(typ == 0x0F) {
        // ISO/IEC 13818-7 ADTS AAC (MPEG-2 lower bit-rate audio)
        _aacIds.push(sid);
        } else if (typ == 0x1B) {
          // ITU-T Rec. H.264 and ISO/IEC 14496-10 (lower bit-rate video)
          _avcId = _avcFallbackId = sid;
        } else if (typ == 0x03 || typ == 0x04) {
          //    ISO/IEC 11172-3 (MPEG-1 audio)
          // or ISO/IEC 13818-3 (MPEG-2 halved sample rate audio)
          _mp3Ids.push(sid);
        }
        if (sid == _audioId) {
          audioFound = true;
          if (typ == 0x0F) { // AAC
            _audioIsAAC = true;
          }
        }
        //  es_info_length
        var sel:uint = _data.readUnsignedShort() & 0xFFF;
        _data.position += sel;
        // loop to next stream
        read += sel + 5;
      }
      if (_audioId <= 0 || !audioFound) {
        if(_audioExtract) {
          // automatically select audio track
          Log.debug("Found " + _aacIds.length + " AAC tracks");
          Log.debug("Found " + _mp3Ids.length + " MP3 tracks");
          if (_aacIds.length > 0) {
            _audioId = _audioFallbackId = _aacIds[0];
            _audioIsAAC = _audioFallbackIsAAC = true;
          } else if (_mp3Ids.length > 0) {
            _audioId = _audioFallbackId = _mp3Ids[0];
            _audioIsAAC = _audioFallbackIsAAC = false;
          }
          Log.debug("Selected audio track: " + _audioId);
        }
      }
      return len + pointerField;
    };
  }
}