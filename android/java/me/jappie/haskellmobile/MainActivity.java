package me.jappie.haskellmobile;

import android.app.Activity;
import android.os.Bundle;
import android.view.View;

public class MainActivity extends Activity implements View.OnClickListener {

    static {
        System.loadLibrary("haskellmobile");
    }

    private native String greet(String name);
    private native void renderUI();
    private native void onButtonClick(View view);
    private native void onLifecycleCreate();
    private native void onLifecycleStart();
    private native void onLifecycleResume();
    private native void onLifecyclePause();
    private native void onLifecycleStop();
    private native void onLifecycleDestroy();
    private native void onLifecycleLowMemory();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        onLifecycleCreate();
        // Render UI from Haskell instead of XML layout
        renderUI();
    }

    @Override
    public void onClick(View v) {
        onButtonClick(v);
    }

    @Override
    protected void onStart() {
        super.onStart();
        onLifecycleStart();
    }

    @Override
    protected void onResume() {
        super.onResume();
        onLifecycleResume();
    }

    @Override
    protected void onPause() {
        super.onPause();
        onLifecyclePause();
    }

    @Override
    protected void onStop() {
        super.onStop();
        onLifecycleStop();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        onLifecycleDestroy();
    }

    @Override
    public void onLowMemory() {
        super.onLowMemory();
        onLifecycleLowMemory();
    }
}
