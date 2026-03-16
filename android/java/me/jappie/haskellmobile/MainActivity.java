package me.jappie.haskellmobile;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

public class MainActivity extends Activity {

    static {
        System.loadLibrary("haskellmobile");
    }

    private native String greet(String name);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        TextView greetingText = findViewById(R.id.greeting_text);
        String greeting = greet("Android");
        greetingText.setText(greeting);
    }
}
