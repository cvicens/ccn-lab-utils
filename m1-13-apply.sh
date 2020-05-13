#!/bin/sh

cat <<EOF | git apply
diff --git a/monolith/pom.xml b/monolith/pom.xml
index 1d751fe..5a0d46c 100644
--- a/monolith/pom.xml
+++ b/monolith/pom.xml
@@ -54,5 +54,27 @@
     </build>
     <profiles>
 <!-- TODO: Add OpenShift profile here -->
+        <profile>
+          <id>openshift</id>
+          <build>
+              <plugins>
+                  <plugin>
+                      <artifactId>maven-war-plugin</artifactId>
+                      <version>2.6</version>
+                      <configuration>
+                          <webResources>
+                              <resource>
+                                  <directory>\${basedir}/src/main/webapp/WEB-INF</directory>
+                                  <filtering>true</filtering>
+                                  <targetPath>WEB-INF</targetPath>
+                              </resource>
+                          </webResources>
+                          <outputDirectory>\${basedir}/deployments</outputDirectory>
+                          <warName>ROOT</warName>
+                      </configuration>
+                  </plugin>
+              </plugins>
+          </build>
+        </profile>
     </profiles>
 </project>
diff --git a/monolith/src/main/java/com/redhat/coolstore/service/InventoryNotificationMDB.java b/monolith/src/main/java/com/redhat/coolstore/service/InventoryNotificationMDB.java
index 35aa746..d8e1f35 100644
--- a/monolith/src/main/java/com/redhat/coolstore/service/InventoryNotificationMDB.java
+++ b/monolith/src/main/java/com/redhat/coolstore/service/InventoryNotificationMDB.java
@@ -3,15 +3,20 @@ package com.redhat.coolstore.service;
 import com.redhat.coolstore.model.Order;
 import com.redhat.coolstore.utils.Transformers;
 
+import javax.ejb.ActivationConfigProperty;
+import javax.ejb.MessageDriven;
 import javax.inject.Inject;
-import javax.jms.*;
-import javax.naming.Context;
-import javax.naming.InitialContext;
-import javax.naming.NamingException;
-import javax.rmi.PortableRemoteObject;
-import java.util.Hashtable;
+import javax.jms.JMSException;
+import javax.jms.Message;
+import javax.jms.MessageListener;
+import javax.jms.TextMessage;
 import java.util.logging.Logger;
 
+@MessageDriven(name = "InventoryNotificationMDB", activationConfig = {
+        @ActivationConfigProperty(propertyName = "destinationLookup", propertyValue = "topic/orders"),
+        @ActivationConfigProperty(propertyName = "destinationType", propertyValue = "javax.jms.Topic"),
+        @ActivationConfigProperty(propertyName = "transactionTimeout", propertyValue = "30"),
+        @ActivationConfigProperty(propertyName = "acknowledgeMode", propertyValue = "Auto-acknowledge")})
 public class InventoryNotificationMDB implements MessageListener {
 
     private static final int LOW_THRESHOLD = 50;
@@ -22,13 +27,6 @@ public class InventoryNotificationMDB implements MessageListener {
     @Inject
     private Logger log;
 
-    private final static String JNDI_FACTORY = "weblogic.jndi.WLInitialContextFactory";
-    private final static String JMS_FACTORY = "TCF";
-    private final static String TOPIC = "topic/orders";
-    private TopicConnection tcon;
-    private TopicSession tsession;
-    private TopicSubscriber tsubscriber;
-
     public void onMessage(Message rcvMessage) {
         TextMessage msg;
         {
@@ -42,8 +40,6 @@ public class InventoryNotificationMDB implements MessageListener {
                         int new_quantity = old_quantity - orderItem.getQuantity();
                         if (new_quantity < LOW_THRESHOLD) {
                             log.warning("Inventory for item " + orderItem.getProductId() + " is below threshold (" + LOW_THRESHOLD + "), contact supplier!");
-                        } else {
-                            orderItem.setQuantity(new_quantity);
                         }
                     });
                 }
@@ -54,29 +50,4 @@ public class InventoryNotificationMDB implements MessageListener {
             }
         }
     }
-
-    public void init() throws NamingException, JMSException {
-        Context ctx = getInitialContext();
-        TopicConnectionFactory tconFactory = (TopicConnectionFactory) PortableRemoteObject.narrow(ctx.lookup(JMS_FACTORY), TopicConnectionFactory.class);
-        tcon = tconFactory.createTopicConnection();
-        tsession = tcon.createTopicSession(false, Session.AUTO_ACKNOWLEDGE);
-        Topic topic = (Topic) PortableRemoteObject.narrow(ctx.lookup(TOPIC), Topic.class);
-        tsubscriber = tsession.createSubscriber(topic);
-        tsubscriber.setMessageListener(this);
-        tcon.start();
-    }
-
-    public void close() throws JMSException {
-        tsubscriber.close();
-        tsession.close();
-        tcon.close();
-    }
-
-    private static InitialContext getInitialContext() throws NamingException {
-        Hashtable<String, String> env = new Hashtable<>();
-        env.put(Context.INITIAL_CONTEXT_FACTORY, JNDI_FACTORY);
-        env.put(Context.PROVIDER_URL, "t3://localhost:7001");
-        env.put("weblogic.jndi.createIntermediateContexts", "true");
-        return new InitialContext(env);
-    }
 }
\ No newline at end of file
diff --git a/monolith/src/main/java/com/redhat/coolstore/service/OrderServiceMDB.java b/monolith/src/main/java/com/redhat/coolstore/service/OrderServiceMDB.java
index dc2225f..c5f4148 100644
--- a/monolith/src/main/java/com/redhat/coolstore/service/OrderServiceMDB.java
+++ b/monolith/src/main/java/com/redhat/coolstore/service/OrderServiceMDB.java
@@ -10,40 +10,41 @@ import javax.jms.TextMessage;
 
 import com.redhat.coolstore.model.Order;
 import com.redhat.coolstore.utils.Transformers;
-import weblogic.i18n.logging.NonCatalogLogger;
+
+import java.util.logging.Logger;
 
 @MessageDriven(name = "OrderServiceMDB", activationConfig = {
-	@ActivationConfigProperty(propertyName = "destinationLookup", propertyValue = "topic/orders"),
-	@ActivationConfigProperty(propertyName = "destinationType", propertyValue = "javax.jms.Topic"),
-	@ActivationConfigProperty(propertyName = "acknowledgeMode", propertyValue = "Auto-acknowledge")})
-public class OrderServiceMDB implements MessageListener { 
-
-	@Inject
-	OrderService orderService;
-
-	@Inject
-	CatalogService catalogService;
-
-	private NonCatalogLogger log = new NonCatalogLogger(OrderServiceMDB.class.getName());
-
-	@Override
-	public void onMessage(Message rcvMessage) {
-		TextMessage msg = null;
-		try {
-				if (rcvMessage instanceof TextMessage) {
-						msg = (TextMessage) rcvMessage;
-						String orderStr = msg.getBody(String.class);
-						log.info("Received order: " + orderStr);
-						Order order = Transformers.jsonToOrder(orderStr);
-						log.info("Order object is " + order);
-						orderService.save(order);
-						order.getItemList().forEach(orderItem -> {
-							catalogService.updateInventoryItems(orderItem.getProductId(), orderItem.getQuantity());
-						});
-				}
-		} catch (JMSException e) {
-			throw new RuntimeException(e);
-		}
-	}
+    @ActivationConfigProperty(propertyName = "destinationLookup", propertyValue = "topic/orders"),
+    @ActivationConfigProperty(propertyName = "destinationType", propertyValue = "javax.jms.Topic"),
+    @ActivationConfigProperty(propertyName = "acknowledgeMode", propertyValue = "Auto-acknowledge")})
+public class OrderServiceMDB implements MessageListener {
+
+    @Inject
+    OrderService orderService;
+
+    @Inject
+    CatalogService catalogService;
+
+    private Logger log = Logger.getLogger(OrderServiceMDB.class.getName());
+
+    @Override
+    public void onMessage(Message rcvMessage) {
+        TextMessage msg = null;
+        try {
+                if (rcvMessage instanceof TextMessage) {
+                        msg = (TextMessage) rcvMessage;
+                        String orderStr = msg.getBody(String.class);
+                        log.info("Received order: " + orderStr);
+                        Order order = Transformers.jsonToOrder(orderStr);
+                        log.info("Order object is " + order);
+                        orderService.save(order);
+                        order.getItemList().forEach(orderItem -> {
+                            catalogService.updateInventoryItems(orderItem.getProductId(), orderItem.getQuantity());
+                        });
+                }
+        } catch (JMSException e) {
+            throw new RuntimeException(e);
+        }
+    }
 
 }
\ No newline at end of file
diff --git a/monolith/src/main/java/com/redhat/coolstore/utils/StartupListener.java b/monolith/src/main/java/com/redhat/coolstore/utils/StartupListener.java
index 3b06ebb..5766370 100644
--- a/monolith/src/main/java/com/redhat/coolstore/utils/StartupListener.java
+++ b/monolith/src/main/java/com/redhat/coolstore/utils/StartupListener.java
@@ -1,24 +1,27 @@
 package com.redhat.coolstore.utils;
 
-import weblogic.application.ApplicationLifecycleEvent;
-import weblogic.application.ApplicationLifecycleListener;
-
+import javax.annotation.PostConstruct;
+import javax.annotation.PreDestroy;
+import javax.ejb.Startup;
+import javax.inject.Singleton;
 import javax.inject.Inject;
 import java.util.logging.Logger;
 
-public class StartupListener extends ApplicationLifecycleListener {
+@Singleton
+@Startup
+public class StartupListener {
 
     @Inject
     Logger log;
 
-    @Override
-    public void postStart(ApplicationLifecycleEvent evt) {
+    @PostConstruct
+    public void postStart() {
         log.info("AppListener(postStart)");
     }
 
-    @Override
-    public void preStop(ApplicationLifecycleEvent evt) {
+    @PreDestroy
+    public void preStop() {
         log.info("AppListener(preStop)");
     }
 
-}
+}
\ No newline at end of file
diff --git a/monolith/src/main/java/weblogic/application/ApplicationLifecycleEvent.java b/monolith/src/main/java/weblogic/application/ApplicationLifecycleEvent.java
deleted file mode 100644
index b140f2d..0000000
--- a/monolith/src/main/java/weblogic/application/ApplicationLifecycleEvent.java
+++ /dev/null
@@ -1,21 +0,0 @@
-/**
- *  Licensed to the Apache Software Foundation (ASF) under one or more
- *  contributor license agreements.  See the NOTICE file distributed with
- *  this work for additional information regarding copyright ownership.
- *  The ASF licenses this file to You under the Apache License, Version 2.0
- *  (the "License"); you may not use this file except in compliance with
- *  the License.  You may obtain a copy of the License at
- *
- *     http://www.apache.org/licenses/LICENSE-2.0
- *
- *  Unless required by applicable law or agreed to in writing, software
- *  distributed under the License is distributed on an "AS IS" BASIS,
- *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
- *  See the License for the specific language governing permissions and
- *  limitations under the License.
- */
-package weblogic.application;
-
-public interface ApplicationLifecycleEvent {
-
-}
diff --git a/monolith/src/main/java/weblogic/application/ApplicationLifecycleListener.java b/monolith/src/main/java/weblogic/application/ApplicationLifecycleListener.java
deleted file mode 100644
index 948d97d..0000000
--- a/monolith/src/main/java/weblogic/application/ApplicationLifecycleListener.java
+++ /dev/null
@@ -1,36 +0,0 @@
-/**
- * Licensed to the Apache Software Foundation (ASF) under one or more
- * contributor license agreements.  See the NOTICE file distributed with
- * this work for additional information regarding copyright ownership.
- * The ASF licenses this file to You under the Apache License, Version 2.0
- * (the "License"); you may not use this file except in compliance with
- * the License.  You may obtain a copy of the License at
- * <p>
- * http://www.apache.org/licenses/LICENSE-2.0
- * <p>
- * Unless required by applicable law or agreed to in writing, software
- * distributed under the License is distributed on an "AS IS" BASIS,
- * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
- * See the License for the specific language governing permissions and
- * limitations under the License.
- */
-package weblogic.application;
-
-public abstract class ApplicationLifecycleListener {
-
-    public void postStart(ApplicationLifecycleEvent evt) {
-
-    }
-
-    public void postStop(ApplicationLifecycleEvent evt) {
-
-    }
-
-    public void preStart(ApplicationLifecycleEvent evt) {
-
-    }
-
-    public void preStop(ApplicationLifecycleEvent evt) {
-
-    }
-}
diff --git a/monolith/src/main/java/weblogic/i18n/logging/NonCatalogLogger.java b/monolith/src/main/java/weblogic/i18n/logging/NonCatalogLogger.java
deleted file mode 100644
index ea50c6c..0000000
--- a/monolith/src/main/java/weblogic/i18n/logging/NonCatalogLogger.java
+++ /dev/null
@@ -1,16 +0,0 @@
-package weblogic.i18n.logging;
-
-public class NonCatalogLogger {
-
-    public NonCatalogLogger() {
-
-    }
-
-    public NonCatalogLogger(String logName) {
-
-    }
-
-    public void info(String msg) {
-
-    }
-}
diff --git a/monolith/src/main/webapp/WEB-INF/weblogic-ejb-jar.xml b/monolith/src/main/webapp/WEB-INF/weblogic-ejb-jar.xml
deleted file mode 100644
index ba9fae0..0000000
--- a/monolith/src/main/webapp/WEB-INF/weblogic-ejb-jar.xml
+++ /dev/null
@@ -1,10 +0,0 @@
-<weblogic-ejb-jar xmlns="http://www.bea.com/ns/weblogic/910" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
-                  xsi:schemaLocation="http://www.bea.com/ns/weblogic/910 http://www.bea.com/ns/weblogic/910/weblogic-ejb-jar.xsd">
-
-<weblogic-enterprise-bean>
-        <ejb-name>InventoryNotificationMDB</ejb-name>
-        <transaction-descriptor>
-            <trans-timeout-seconds>30</trans-timeout-seconds>
-        </transaction-descriptor>
-    </weblogic-enterprise-bean>
-</weblogic-ejb-jar>
EOF

mvn -f ./monolith clean package

