FROM docker:29-dind

RUN apk add --no-cache openssh-server

RUN ssh-keygen -A \
 && adduser -D -s /bin/sh deploy \
 && addgroup deploy docker \
 && passwd -u deploy \
 && mkdir -p /home/deploy/.ssh

COPY id_ed25519.pub /home/deploy/.ssh/authorized_keys

RUN chown -R deploy:deploy /home/deploy/.ssh \
 && chmod 700 /home/deploy/.ssh \
 && chmod 600 /home/deploy/.ssh/authorized_keys

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
