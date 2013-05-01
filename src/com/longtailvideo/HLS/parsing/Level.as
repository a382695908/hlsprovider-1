package com.longtailvideo.HLS.parsing {


    import com.longtailvideo.HLS.parsing.Fragment;
    import flash.utils.ByteArray;


    /** Adaptive streaming quality level. **/
    public class Level {


        /** Audio configuration packet (ADIF). **/
        public var adif:ByteArray;
        /** Whether this is audio only. **/
        public var audio:Boolean;
        /** Video configuration packet (AVCC). **/
        public var avcc:ByteArray;
        /** Bitrate of the video in this level. **/
        public var bitrate:Number;
        /** Array with fragments for this level. **/
        private var fragments:Array;
        /** Height of the video in this level. **/
        public var height:Number;
        /** URL of this bitrate level (for M3U8). **/
        public var url:String;
        /** Width of the video in this level. **/
        public var width:Number;
        /** min sequence number from M3U8. **/
        public var minseqnum:Number;
        /** max sequence number from M3U8. **/
        public var maxseqnum:Number;

        /** Create the quality level. **/
        public function Level(bitrate:Number=150000, height:Number=90, width:Number=160):void {
            this.bitrate = bitrate;
            this.height = height;
            this.width = width;
            this.fragments = new Array();
        };

        /** Return the fragment matching with a time position. **/
        public function getFragmentfromPosition(position:Number):Fragment {
            for(var i:Number = 0; i < fragments.length; i++) {
                if(fragments[i].start <= position && fragments[i].start + fragments[i].duration > position) {
                    return fragments[i];
                }
            }
            return null;
        };

        /** Return the fragment index from fragment sequence number **/
        public function getFragmentfromSeqNum(seqnum:Number):Fragment {
            var index:Number;
            if(seqnum >= minseqnum && seqnum <= maxseqnum) {
               index =fragments.length-1 - (maxseqnum - seqnum);
               return fragments[index];
            } else {
               return null;
            }
        };

        /** set Fragments **/
        public function setFragments(_fragments:Array):void {
            fragments = _fragments;
        };
    }
}