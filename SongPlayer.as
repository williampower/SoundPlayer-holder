package com.mypowerapps{
	import flash.events.Event;
	import flash.events.IEventDispatcher;
	import flash.media.Sound;
	import flash.media.SoundChannel;
	import flash.net.NetConnection;
	import flash.net.NetStream;
	import flash.media.Video;
	import flash.events.EventDispatcher;
	import flash.events.AsyncErrorEvent;
	import flash.events.DRMAuthenticateEvent;
	import flash.events.DRMErrorEvent;
	import flash.events.DRMStatusEvent;
	import flash.events.NetStatusEvent;
	import flash.errors.IOError;
	import flash.events.IOErrorEvent;
	import flash.events.SecurityErrorEvent;
	import flash.net.URLRequest;
	import flash.media.ID3Info;
	import flash.media.SoundTransform;
	import flash.events.ProgressEvent;
	import mx.controls.Alert;
	import event.PlayNext;
	import flash.media.SoundMixer;
	import mx.collections.ArrayCollection;
	import flash.desktop.NativeApplication;
	import mx.core.UIComponent;
	import mx.rpc.soap.SOAPFault;

	[Event(name="PlayNext",type="event.PlayNext")]
	[Event(name="GoToPlaying",type="flash.events.Event")]
	[Event(name="GoToPausing",type="flash.events.Event")]
	public class SongPlayer implements IEventDispatcher{
		/*
		TODO: TRACK WHAT 'LOAD' HAS BEEN CALLED ON SO IT CAN BE
		STOPPED IF TOO MANY 'LOAD' CALLS COME IN AT ONCE.
		 */
//		private var loadingQueue:ArrayCollection;
		private var orphanSongQueue:ArrayCollection;
		private var lastURLRequested:String;
		private var lastSound:Sound;
		
		[Bindable]
		public var hasSong:Boolean = false;
		[Bindable]
		public var bIsPlaying:Boolean = false;
		private var bIsLoading:Boolean = false;
		private var bStreamIsPaused:Boolean = false;
		
		//time stuff
		private const MS_PER_SEC:Number = 1000;
		private const SEC_PER_MIN:Number = 60;
		private const MIN_PER_HOUR:Number = 60;
		
		//new
		private var _currentURL:String;
		private var _currentVid:Video;
		private var _cc:CustomClient;
		
		//old mp3 stuff
		private var urlReq:URLRequest;
		private var sound:Sound;
		private var soundChannel:SoundChannel;
		
		//old & possibly useful mp3 stuff
		private var songInfo:String;
		private var _songPlayhead:Number;
		private var soundTrans:SoundTransform;
		//song length in MS
		private var _songLength:Number;
		
		//streaming
		private var nc:NetConnection;
		private var ns:NetStream;
		private var streamURL:String;
		
		//event dispatch
		private var _ed:EventDispatcher;
		
		//playMode: default MP3
		private const MODE_MP3:String = "MP3";
		private const MODE_STREAM:String = "STREAM";
		private var playMode:String = MODE_MP3;
		
		
	//=============================================================================
	//	LIFECYCLE 
	//=============================================================================
	public function SongPlayer(vid:Video){
//		loadingQueue = new ArrayCollection();
		orphanSongQueue = new ArrayCollection();
		
		_ed = new EventDispatcher(this);
		soundTrans = new SoundTransform(1,0);

		//TODO: implement function
		nc = new NetConnection();
		nc.addEventListener(Event.ACTIVATE,handleNetConn_activate,false,0,true);
		nc.addEventListener(AsyncErrorEvent.ASYNC_ERROR,handleNetConn_asyncError,false,0,true);
		nc.addEventListener(Event.DEACTIVATE,handleNetConn_deactivate,false,0,true);
		nc.addEventListener(IOErrorEvent.IO_ERROR,handleNetConn_ioError,false,0,true);
		nc.addEventListener(NetStatusEvent.NET_STATUS,handleNetConn_netStatus,false,0,true);
		nc.addEventListener(SecurityErrorEvent.SECURITY_ERROR,handleNetConn_securityError,false,0,true);
		nc.connect(null);
		
		_currentVid = vid;
		_cc = new CustomClient();
	} //end


	//===============================================================================
	//SONG INTERFACE
	//===============================================================================
	/**
	 * Given a URL, loads & plays new song.
	 */
	public function startNewSong(url:String):void{
//		trace("startNewSong");
		if(bIsPlaying){
			pauseSong();
		}
/*		else if(bIsLoading){
			trace("new while loading");
			pauseSong();
			if(playMode == MODE_MP3){
				//stop loading mp3
				sound = null;
				soundChannel = null;
			}else if(playMode == MODE_STREAM){
				
			}
		} 
		*/
		loadSong(url);
	} //end startNewSong
	//pass with pos==SongPlayer.playhead to 'unpause'
	public function playSong(pos:Number):void{
		if(pos && ns && ns.time && _songLength){
			trace("playSong(" + pos.toString() + ") with time/dur: " +
					ns.time.toString() + "/" + _songLength.toString());
		}
		if(pos >= _songLength){
			onSongDone(new Event("fromPlaySong"));
			return;
		}
//		trace("playSong at " + pos.toString());
		switch(playMode){
			case MODE_MP3:
				play_MP3(pos);
				break;
			case MODE_STREAM:
				if(bStreamIsPaused){
					play_Stream(pos);
				}else{
					play_Stream(pos);
				}
				break;
		}
		//dispatch event indicating you're playing?
	} //end playSong
	public function pauseSong():void{
		bIsPlaying = false;
		switch(playMode){
			case MODE_MP3:
				if(soundChannel){
					_songPlayhead = soundChannel.position;
					soundChannel.stop();
					soundChannel.removeEventListener(Event.SOUND_COMPLETE,onSongDone);
				}
				break;
			case MODE_STREAM:
				trace("toggle pause");
				ns.togglePause();
				bStreamIsPaused = true;
				break;
		}
		_ed.dispatchEvent(new Event("GoToPausing",true));
	} //end stopSong

	private function onSongDone(e:Event):void{
		trace("song done");
		pauseSong();
		switch(playMode){
			case MODE_MP3:
				if(sound){
					sound.removeEventListener(Event.ID3,handleID3Info);
				}
				break;
			case MODE_STREAM:
				//???
				break;
		}
		_songPlayhead = 0;
		_ed.dispatchEvent(new PlayNext());
	} //end onSongDone


	//=============================================================================
	// SONG LOADER HELPER FUNCTIONS
	//=============================================================================
	private function loadSong(url:String):void{
		trace("loadSong " + MyURLUtil.cleanURL(url));
		/*
		track the url of the last load request, use it in the 'handleComplete' functions
		to ignore other songs
		
		Also...find a way to stop all other asynch requests right then!
		*/

		lastURLRequested = url;
		
		//handle still-loading MP3 songs here
		if(sound && (sound.bytesLoaded != sound.bytesTotal) ){
			sound.removeEventListener(Event.ID3,handleID3Info);
			sound.removeEventListener(IOErrorEvent.IO_ERROR,handleLoadError);
			sound.removeEventListener(ProgressEvent.PROGRESS,handleLoadProgress);
			sound.removeEventListener(Event.COMPLETE,handleLoadComplete);
			try{
				trace("CLOSING " + MyURLUtil.cleanURL(sound.url));
				sound.close();
			}catch(e:Error){
				trace("WTF");
				orphanSongQueue.addItem(sound);
			}
		}
		var tmpSound:Sound;
		for(var i:int = orphanSongQueue.length-1; i >= 0; i--){
			tmpSound = orphanSongQueue[i];
			if(tmpSound){
				try{
					tmpSound.close();
					orphanSongQueue.removeItemAt(i);
				}catch(e:Error){
					trace("WTF WTF");
				}
			}
		}

		setPlayMode(url);

		bStreamIsPaused = false;
		_songPlayhead = 0;
		setSongInfo(buildLabelFromURL(url));

		
		switch(playMode){
			case MODE_MP3:
				bIsLoading = true;
				urlReq = new URLRequest(url);
//				if(sound){ clearLoadingQueue(); }
				sound = new Sound();
				sound.addEventListener(Event.ID3,handleID3Info,false,0,true);
				sound.addEventListener(IOErrorEvent.IO_ERROR,handleLoadError,false,0,true);
				sound.addEventListener(ProgressEvent.PROGRESS,handleLoadProgress,false,0,true);
				sound.addEventListener(Event.COMPLETE,handleLoadComplete,false,0,true);
				sound.load(urlReq);
//				trace("called load for " + MyURLUtil.cleanURL(urlReq.url));
				break;
			case MODE_STREAM:
				if(ns){
					//close makes ready for reuse
					trace("close ns");
					ns.close();
					ns.removeEventListener(Event.ACTIVATE,handleNetStream_activate);
					ns.removeEventListener(AsyncErrorEvent.ASYNC_ERROR,handleNetStream_asyncError);
					ns.removeEventListener(Event.DEACTIVATE,handleNetStream_deactivate);
					ns.removeEventListener(DRMAuthenticateEvent.DRM_AUTHENTICATE,handleNetStream_drmAuthenticate);
					ns.removeEventListener(DRMErrorEvent.DRM_ERROR,handleNetStream_drmError);
					ns.removeEventListener(DRMStatusEvent.DRM_STATUS,handleNetStream_drmStatus);
					ns.removeEventListener(IOErrorEvent.IO_ERROR,handleNetStream_ioError);
					ns.removeEventListener(NetStatusEvent.NET_STATUS,handleNetStream_netStatus);
				}
//				else{
					//create & do all setup
					trace("new ns");
					ns = new NetStream(nc);
					ns.addEventListener(Event.ACTIVATE,handleNetStream_activate,false,0,true);
					ns.addEventListener(AsyncErrorEvent.ASYNC_ERROR,handleNetStream_asyncError,false,0,true);
					ns.addEventListener(Event.DEACTIVATE,handleNetStream_deactivate,false,0,true);
					ns.addEventListener(DRMAuthenticateEvent.DRM_AUTHENTICATE,handleNetStream_drmAuthenticate,false,0,true);
					ns.addEventListener(DRMErrorEvent.DRM_ERROR,handleNetStream_drmError,false,0,true);
					ns.addEventListener(DRMStatusEvent.DRM_STATUS,handleNetStream_drmStatus,false,0,true);
					ns.addEventListener(IOErrorEvent.IO_ERROR,handleNetStream_ioError,false,0,true);
					ns.addEventListener(NetStatusEvent.NET_STATUS,handleNetStream_netStatus,false,0,true);
					ns.client = this;
					_currentVid.attachNetStream(ns);
//				}
				play_Stream(0);
				break;
		}
	} //end loadSong
	private function play_MP3(pos:Number):void{
		//check for pos > length done before calling this
		soundChannel = sound.play(pos,0,soundTrans);
		soundChannel.addEventListener(Event.SOUND_COMPLETE,onSongDone);
		goToPlaying();
	} //end playMP3
	private function play_Stream(pos:Number):void{
		//check for pos > length done before calling this
		if(Math.abs(pos) < 0.0001){
			trace("play from start");
			ns.play(_currentURL);
		}else if(!bIsPlaying && pos == this._songPlayhead){
			trace("togglePause");
			ns.togglePause();
		}else if( pos > 0.0001 ){
			trace("pos > 0.0001");
			ns.seek(pos/1000);
			//gets picked up by handleNetStream_netStatus
		}else{
			trace("first time play");
			//first-time play
			ns.play(_currentURL);
			_ed.dispatchEvent(new Event("GoToPausing",true));
		}
		goToPlaying();
	} //end playStreaming
	private function goToPlaying():void{
		bIsPlaying = true;
		_ed.dispatchEvent(new Event("GoToPlaying",true));
	}





	//=============================================================================
	// STREAMING STUFF (NETSTREAM CLIENT)
	//=============================================================================
    public function onCuePoint(info:Object):void {
		trace("onCuePoint: time=" + info.time + " name=" + info.name + " type=" + info.type);
    } //end onCuePoint
    public function onImageData(info:Object):void{
		trace("onImageData");
    } //end onImageData
    public function onMetaData(info:Object):void {
		trace("onMetaData: duration=" + info.duration + " width=" + info.width + " height=" + info.height + " framerate=" + info.framerate);
		this._songLength = (info.duration as Number) * 1000;
    } //end onMetadata
    public function onPlayStatus(info:Object):void{
    	trace("onPlayStatus");
    } //end onPlayStatus
    public function onTextData(info:Object):void{
    	trace("onTextData");
    } //end onTextData
    public function onXMPData(info:Object):void{
    	trace("onXMPData");
    } //end onXMPData
    public function onDRMContentData(info:Object):void{
    	trace("onDRMContentData");
    }
	//=============================================================================
	// STREAMING STUFF (EVENT HANDLERS)
	//=============================================================================
	private function handleNetStream_activate(e:Event):void{
		//trace("NS: activate");
	}
	private function handleNetStream_asyncError(e:AsyncErrorEvent):void{
		trace("NS: asyncError"); 
	}
	private function handleNetStream_deactivate(e:Event):void{
		//trace("NS: deactivate");
	}
	private function handleNetStream_drmAuthenticate(e:DRMAuthenticateEvent):void{
		trace("NS: drmAuthenticate");
	}
	private function handleNetStream_drmError(e:DRMErrorEvent):void{
		trace("NS: drmError");
	}
	private function handleNetStream_drmStatus(e:DRMStatusEvent):void{
		trace("NS: drmStatus");
	}
	private function handleNetStream_ioError(e:IOErrorEvent):void{
		trace("NS: ioError");
	}
	private function handleNetStream_netStatus(e:NetStatusEvent):void{
		switch(e.info.code as String){
			case "NetStream.Buffer.Flush":
				//TODO: PUT BACK IN IF SOMETHING BREAKS
				break;
			case "NetStream.Play.Stop":
				onSongDone(new Event("StreamDone"));
				break;
			case "NetStream.Seek.Notify":
				/*
				Gets here two ways: 
				1) after clicking in the timeline
				2) after releasing a 'drag' on the timeline
				*/
				ns.togglePause();
				break;
			case "NetStream.Buffer.Empty":
				/*to provoke this: start playing song (m4a?) on J drive, then
				  turn off J drive. When buffer is empty, this occurs.
				  Figure out what to do here. Should this set state to 'paused' 
				  and give a warning? How do we resume play after that?
				*/
				trace("Buffer Empty at time " + (e.target as NetStream).time.toString());
				break;
			default:
				trace("NS: netStatus " + (e.info.code as String) + " at time " + (e.target as NetStream).time.toString());
		}
	} //end handleNetStream_netStatus









	//=============================================================================
	//MP3 HANDLING
	//=============================================================================
	private function handleLoadProgress(e:ProgressEvent):void{
		var loadPct:uint = Math.round(100*(e.bytesLoaded/e.bytesTotal));
//		trace(loadPct.toString() + "%"); 
	}
	private function handleLoadError(e:IOErrorEvent):void{
		trace("load failed"); 
		Alert.show("IOError: " + e.errorID + " for " + e.text);
	}
	private function removeAllSongListeners():void{
		if(sound){
			sound.removeEventListener(Event.ID3,handleID3Info);
			sound.removeEventListener(Event.COMPLETE,handleLoadComplete);
		} //end if currentSong
	} //end removeAllSongListeners
	private function handleLoadComplete(e:Event):void{
		var s:Sound = e.target as Sound;
		if(!s){ return; }
		trace("load complete " + MyURLUtil.cleanURL(s.url));
		sound.removeEventListener(IOErrorEvent.IO_ERROR,handleLoadError);
		sound.removeEventListener(ProgressEvent.PROGRESS,handleLoadProgress);
		sound.removeEventListener(Event.COMPLETE,handleLoadComplete);

//		loadingQueue.removeItemAt(loadingQueue.getItemIndex(s));
		
		/*
		if this url doesn't match the last loaded, don't play it
		 */

		_songLength = sound.length;
		
		if(s.url != lastURLRequested){
			trace("LATE: " + MyURLUtil.cleanURL(s.url) );
		}
		for each (var lateSound:Sound in orphanSongQueue){
			try{
				lateSound.close();
				orphanSongQueue.removeItemAt(orphanSongQueue.getItemIndex(lateSound));
			}catch(e:Error){
				trace("cannot yet close " + MyURLUtil.cleanURL(lateSound.url));
			}
		}
		if(s.url == lastURLRequested){
			play_MP3(0);
		}
	}

	
	private function handleID3Info(e:Event):void{
		var id3:ID3Info = e.currentTarget.id3 as ID3Info;
		if(id3.songName && id3.songName.length > 0){
			setSongInfo(id3.songName);
//			songInfo = id3.songName;
		}
		if(id3.artist && id3.artist.length > 0){
//			songInfo = lblSongLabel.text + " - " + id3.artist;
		}
//		lblSongLabel.toolTip = lblSongLabel.text;
		//TODO: dispatch event indicating songLabel changed
	} //end handleID3Info








	//=============================================================================
	// SONG DATA
	//=============================================================================
	//----------volume-----------------------
	public function set volume(value:Number):void{
		if(value > 100){
			soundTrans.volume = 100;
		}else if(value < 0){
			soundTrans.volume = 0;
		}else{
			soundTrans.volume = value;
		}
		//TODO: RESET VOLUME ON MP3/STREAM?
		switch(playMode){
			case MODE_MP3:
				soundChannel.soundTransform = soundTrans;
				break;
			case MODE_STREAM:
				ns.soundTransform = soundTrans;
				break;
		}
	} //end set volume
	public function get volume():Number{
		return soundTrans.volume;
	}
	
	//todo: make this dispatch an event when it changes
	[Bindable(event="songLabelChanged")]
	public function set songLabel(value:String):void{
		//do nothing
	}
	public function get songLabel():String{
		return songInfo;
	}
	private function setSongInfo(value:String):void{
		songInfo = value;
		_ed.dispatchEvent(new Event("songLabelChanged"));
	}
	
	public function get currentURL():String{
		return _currentURL;
	}
	public function get currentPlayhead():Number{
		switch(playMode){
			case MODE_MP3:
//				return _songPlayhead;
				break;
			case MODE_STREAM:
				_songPlayhead = ns.time * 1000 / _songLength;
				break;
		}
		return _songPlayhead;
	}
	public function get songLength():Number{
		return _songLength;
	}
	public function get label_SongLength():String{
		return getTimeString(songLength);
	}
	public function get label_SongPlayhead():String{
		switch(playMode){
			case MODE_MP3:
				return getTimeString(soundChannel.position);
			case MODE_STREAM:
				return getTimeString(ns.time * 1000);
		}
		return "garbage label_SongPlayHead";
	} //end 

	//---------percent played--------------------
	public function getPercentPlayed():Number{
		switch(playMode){
			case MODE_MP3:
				return percentPlayed_MP3();
				break;
			case MODE_STREAM:
				return percentPlayed_Stream();
				break;
			default:
				trace("shit broke in getPercentPlayed");
		}
		return 0.0;
	} //end getPercentPlayed
	private function percentPlayed_MP3():Number{
		if(soundChannel){
			return soundChannel.position / _songLength;
		}
		return 0.0;
	} //end percentPlayedMP3
	private function percentPlayed_Stream():Number{
		return ns.time * 1000 / _songLength;
	} //end percentPlayed_Stream

	public function getTimeString(ms:Number):String{
		var timeStr:String = "";
		var hrs:Number = Math.floor(ms/MS_PER_SEC/SEC_PER_MIN/MIN_PER_HOUR);
		var mins:Number = Math.floor(ms/MS_PER_SEC/SEC_PER_MIN)%MIN_PER_HOUR;
		var secs:Number = Math.floor(ms/MS_PER_SEC)%SEC_PER_MIN;
		if(hrs > 0.0){
			timeStr += getNumWithSpacer(hrs," ") + ":";
			timeStr += getNumWithSpacer(mins,"0") + ":";
		}else{
			timeStr += getNumWithSpacer(mins," ") + ":";
		}
		timeStr += getNumWithSpacer(secs,"0");
		return timeStr;
	}
	private function getNumWithSpacer(value:Number,spacer:String):String{
		var _retVal:String = value.toString();
		if(value < 0){
			_retVal = _retVal.replace("-","");
		}
		if(_retVal.length < 2){
			return spacer + _retVal;
		}
		return _retVal;
	} //end getNumWithSpacer


	private function setPlayMode(url:String):void{
		_currentURL = url;
		if(_currentURL.lastIndexOf(".mp3") > 0){
			playMode = MODE_MP3;
		}else{
			playMode = MODE_STREAM;
		}
	} //end setPlayMode
	private function buildLabelFromURL(url:String):String{
		return MyURLUtil.cleanURL(url);
	} //end buildLabelFromURL
















	//=============================================================================
	//event listener stuff
	//=============================================================================
	public function addEventListener(type:String, listener:Function,
			useCapture:Boolean=false, priority:int=0,useWeakReference:Boolean=false):void {
		_ed.addEventListener(type, listener, useCapture, 
			priority, useWeakReference);
	}
	public function removeEventListener(type:String, listener:Function,
		useCapture:Boolean=false):void {
		_ed.removeEventListener(type, listener, useCapture);
	}
	public function dispatchEvent(event:Event):Boolean {
		return _ed.dispatchEvent(event);
	}
	public function hasEventListener(type:String):Boolean {
		return _ed.hasEventListener(type);
	}
	public function willTrigger(type:String):Boolean {
		return _ed.willTrigger(type);
	}		



	//=============================================================================
	//netConnection stuff
	//=============================================================================
	private function handleNetConn_activate(e:Event):void{
		//trace("nc: activate ");
	}
	private function handleNetConn_asyncError(e:AsyncErrorEvent):void{
		trace("nc: asyncError " + e.text);
	}
	private function handleNetConn_deactivate(e:Event):void{
		//trace("nc: deactivate ");	
	}
	//thrown by: connect()
	private function handleNetConn_ioError(e:IOErrorEvent):void{
		trace("nc: ioError " + e.text);
	}
	private function handleNetConn_netStatus(e:NetStatusEvent):void{
		trace("nc: netStatus " + e.info.code);
		switch(e.info.code){
			case "NetStream.Play.FileStructureInvalid":
				break;
			case "NetStream.Play.NoSupportedTrackFound":
				break;
			case "NetStream.Play.StreamNotFound":
				trace("for " + streamURL);
				break;
			case "NetStream.Play.Start":
				trace("for " + streamURL);
				break;
			case "NetStream.Buffer.Full":
				trace("for " + streamURL);
				break;
			default: 
				break;
		} //end switch
	}
	//thrown by: call()
	private function handleNetConn_securityError(e:SecurityErrorEvent):void{
		trace("nc: securityError " + e.text);
	} 



	} //end class
} //end package